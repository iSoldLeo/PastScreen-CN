//
//  FileOutputService.swift
//  Mio
//
//  The sole owner of screenshot filename sequence and no-overwrite file
//  publication. Security-scoped URL lifetime remains owned by module 10.
//

import Darwin
import Foundation

actor FileOutputService {
    nonisolated private static let sequenceDefaultsKey = "screenshotSequence"
    nonisolated private static let maximumTemporaryNameAttempts = 8
    private var currentSequence: Int?
    private let saveFolderAccess: SaveFolderAccess
    private let fileManager = FileManager()

    init(saveFolderAccess: SaveFolderAccess) {
        self.saveFolderAccess = saveFolderAccess
    }

    func write(
        pngData: Data,
        capturedAt: CaptureTimestamp,
        organization: FileOrganization
    ) async -> FileDeliveryOutcome {
        guard !Task.isCancelled else { return .cancelledDuringAttempt }
        let outcome: FileDeliveryOutcome
        do {
            outcome = try await saveFolderAccess.withAccess { [self] rootURL in
                try await publish(
                    pngData: pngData,
                    rootURL: rootURL,
                    capturedAt: capturedAt,
                    organization: organization
                )
            }
        } catch is CancellationError {
            outcome = Task.isCancelled
                ? .cancelledDuringAttempt
                : .failed(.authorizationUnavailable)
        } catch let failure as SaveFolderFailure {
            outcome = Task.isCancelled
                ? .cancelledDuringAttempt
                : .failed(.authorization(failure))
        } catch let failure as FileDeliveryFailure {
            outcome = Task.isCancelled ? .cancelledDuringAttempt : .failed(failure)
        } catch {
            outcome = Task.isCancelled
                ? .cancelledDuringAttempt
                : .failed(Self.mapFilesystemFailure(error, defaultFailure: .atomicPublishFailed))
        }

        return outcome
    }

    private func publish(
        pngData: Data,
        rootURL: URL,
        capturedAt: CaptureTimestamp,
        organization: FileOrganization
    ) throws -> FileDeliveryOutcome {
        try Task.checkCancellation()
        let folderURL = try destinationFolder(
            rootURL: rootURL,
            capturedAt: capturedAt,
            organization: organization
        )
        do {
            try fileManager.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Self.mapFilesystemFailure(error, defaultFailure: .directoryCreationFailed)
        }

        let tempURL = try writeExclusiveTemporaryFile(pngData, in: folderURL)
        var published = false
        defer {
            if !published {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        var sequence = loadSequenceIfNeeded()
        while true {
            try Task.checkCancellation()
            guard sequence < Int.max else {
                throw FileDeliveryFailure.nameAllocationFailed
            }
            let finalURL = folderURL.appendingPathComponent("Screen-\(sequence).png")
            let result = Self.renameExclusively(from: tempURL, to: finalURL)
            switch result {
            case .success:
                published = true
                persistSequence(sequence + 1)
                return .saved
            case .destinationExists:
                guard sequence < Int.max else {
                    throw FileDeliveryFailure.nameAllocationFailed
                }
                sequence += 1
            case let .failed(errorNumber):
                if Task.isCancelled { throw CancellationError() }
                throw Self.mapErrno(errorNumber)
            }
        }
    }

    private func destinationFolder(
        rootURL: URL,
        capturedAt: CaptureTimestamp,
        organization: FileOrganization
    ) throws -> URL {
        guard organization == .yearAndMonth else { return rootURL }
        guard let timeZone = TimeZone(identifier: capturedAt.timeZoneIdentifier) else {
            throw FileDeliveryFailure.invalidCaptureTimestamp
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: capturedAt.instant)
        guard let year = parts.year, let month = parts.month, (1...12).contains(month) else {
            throw FileDeliveryFailure.invalidCaptureTimestamp
        }
        return rootURL
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
    }

    private func writeExclusiveTemporaryFile(_ data: Data, in folderURL: URL) throws -> URL {
        for _ in 0..<Self.maximumTemporaryNameAttempts {
            try Task.checkCancellation()
            let url = folderURL.appendingPathComponent(".mio_\(UUID().uuidString).tmp")
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch {
                if Self.isFileExists(error) { continue }
                let wasCancelled = Task.isCancelled
                try? fileManager.removeItem(at: url)
                if wasCancelled { throw CancellationError() }
                throw Self.mapFilesystemFailure(error, defaultFailure: .temporaryWriteFailed)
            }
        }
        throw FileDeliveryFailure.nameAllocationFailed
    }

    private func loadSequenceIfNeeded() -> Int {
        if let currentSequence { return currentSequence }
        let stored = UserDefaults.standard.integer(forKey: Self.sequenceDefaultsKey)
        let sequence = stored > 0 ? stored : 1
        currentSequence = sequence
        return sequence
    }

    private func persistSequence(_ value: Int) {
        currentSequence = value
        UserDefaults.standard.set(value, forKey: Self.sequenceDefaultsKey)
    }

    nonisolated private enum ExclusiveRenameResult {
        case success
        case destinationExists
        case failed(Int32)
    }

    nonisolated private static func renameExclusively(from source: URL, to destination: URL) -> ExclusiveRenameResult {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    return .failed(EINVAL)
                }
                let status = renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
                guard status != 0 else { return .success }
                let errorNumber = errno
                return errorNumber == EEXIST ? .destinationExists : .failed(errorNumber)
            }
        }
    }

    nonisolated private static func mapErrno(_ errorNumber: Int32) -> FileDeliveryFailure {
        switch errorNumber {
        case EACCES, EPERM, EROFS: .permissionDenied
        case ENOSPC, EDQUOT: .diskFull
        case ENOTSUP, EOPNOTSUPP: .atomicPublishUnsupported
        default: .atomicPublishFailed
        }
    }

    nonisolated private static func mapFilesystemFailure(
        _ error: Error,
        defaultFailure: FileDeliveryFailure
    ) -> FileDeliveryFailure {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return mapErrno(Int32(nsError.code))
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError: return .permissionDenied
            case NSFileWriteOutOfSpaceError: return .diskFull
            default: break
            }
        }
        return defaultFailure
    }

    nonisolated private static func isFileExists(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EEXIST))
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError)
    }

}
