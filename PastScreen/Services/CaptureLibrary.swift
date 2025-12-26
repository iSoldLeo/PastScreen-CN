//
//  CaptureLibrary.swift
//  PastScreen
//
//  Lightweight local capture library: metadata in SQLite + assets on disk.
//

import AppKit
import Foundation

// MARK: - Library Service (async + non-blocking)

final class CaptureLibrary {
    static let shared = CaptureLibrary()

    private let worker = CaptureLibraryWorker()
    private let pendingLock = NSLock()
    private var pendingJobs: Int = 0
    private let maxPendingJobs: Int = 8
    private let indexingLock = NSLock()
    private var pendingIndexJobs: Int = 0
    private let maxPendingIndexJobs: Int = 2

    private init() {}

    func bootstrapIfNeeded() {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        let legacyPaths = AppSettings.shared.captureHistory
        _ = enqueue(priority: .utility) { worker in
            try await worker.prepareIfNeeded()
            await worker.migrateLegacyHistoryIfNeeded(legacyPaths: legacyPaths)
        }
    }

    @discardableResult
    func addCapture(
        id: UUID = UUID(),
        cgImage: CGImage,
        pointSize: CGSize,
        captureType: CaptureItemCaptureType,
        captureMode: CaptureItemCaptureMode,
        trigger: CaptureItemTrigger,
        appBundleID: String?,
        appName: String?,
        appPID: Int?,
        externalFilePath: String?,
        ocrText: String? = nil,
        ocrLangs: [String] = []
    ) -> UUID? {
        guard AppSettings.shared.captureLibraryEnabled else { return nil }

        let storePreviews = AppSettings.shared.captureLibraryStorePreviews
        let autoOCR = AppSettings.shared.captureLibraryAutoOCR
        let autoOCRPreferredLanguages = AppSettings.shared.ocrRecognitionLanguages
        let createdAt = Date()

        let job = CaptureLibraryAddJob(
            id: id,
            createdAt: createdAt,
            captureType: captureType,
            captureMode: captureMode,
            trigger: trigger,
            appBundleID: appBundleID,
            appName: appName,
            appPID: appPID,
            selectionSize: pointSize,
            externalFilePath: externalFilePath,
            cgImage: cgImage,
            storePreview: storePreviews,
            ocrText: ocrText,
            ocrLangs: ocrLangs,
            autoOCR: autoOCR,
            autoOCRPreferredLanguages: autoOCRPreferredLanguages
        )

        let enqueued = enqueue(priority: .utility) { worker in
            try await worker.addCapture(job: job)
        }

        return enqueued ? id : nil
    }

    func updateExternalFilePath(for id: UUID, path: String?) {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        _ = enqueue(priority: .utility) { worker in
            try await worker.updateExternalFilePath(for: id, path: path, now: Date())
        }
    }

    func fetchItems(query: CaptureLibraryQuery, limit: Int = 200, offset: Int = 0) async -> [CaptureItem] {
        guard AppSettings.shared.captureLibraryEnabled else { return [] }
        do {
            return try await worker.fetchItems(query: query, limit: limit, offset: offset)
        } catch {
            logError("CaptureLibrary fetchItems failed: \(error.localizedDescription)", category: "LIB")
            return []
        }
    }

    func fetchAppGroups() async -> [CaptureLibraryAppGroup] {
        guard AppSettings.shared.captureLibraryEnabled else { return [] }
        do {
            return try await worker.fetchAppGroups()
        } catch {
            logError("CaptureLibrary fetchAppGroups failed: \(error.localizedDescription)", category: "LIB")
            return []
        }
    }

    func fetchTagGroups() async -> [CaptureLibraryTagGroup] {
        guard AppSettings.shared.captureLibraryEnabled else { return [] }
        do {
            return try await worker.fetchTagGroups()
        } catch {
            logError("CaptureLibrary fetchTagGroups failed: \(error.localizedDescription)", category: "LIB")
            return []
        }
    }

    func setTags(_ tags: [String], for id: UUID) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.setTags(tags, for: id, now: Date())
        } catch {
            logError("CaptureLibrary setTags failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func updateNote(_ note: String?, for id: UUID) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.updateNote(for: id, note: note, now: Date())
        } catch {
            logError("CaptureLibrary updateNote failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func updateEmbedding(
        for id: UUID,
        model: String,
        dim: Int,
        embedding: Data,
        sourceHash: String
    ) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.updateEmbedding(for: id, model: model, dim: dim, embedding: embedding, sourceHash: sourceHash, now: Date())
        } catch {
            logError("CaptureLibrary updateEmbedding failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    @discardableResult
    func requestOCR(for id: UUID, imageURL: URL, preferredLanguages: [String]) -> Bool {
        guard AppSettings.shared.captureLibraryEnabled else { return false }
        let path = imageURL.path
        let languages = preferredLanguages

        return enqueueIndexing(priority: .utility) { worker in
            guard FileManager.default.fileExists(atPath: path) else { return }
            let cgImage = OCRService.loadCGImage(from: imageURL)
                ?? NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            guard let cgImage else { return }

            let text = try await OCRService.recognizeText(
                in: cgImage,
                imageSize: CGSize(width: cgImage.width, height: cgImage.height),
                region: nil,
                preferredLanguages: languages.isEmpty ? nil : languages,
                qos: .utility
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            try await worker.updateOCR(for: id, text: trimmed, langs: languages, now: Date(), notify: true)
        }
    }

    func fetchOCRReindexCandidates(
        targetLangs: String,
        limit: Int,
        cursorCreatedAtMillis: Int64?,
        cursorID: String?
    ) async -> [CaptureLibraryOCRReindexCandidate] {
        do {
            return try await worker.fetchOCRReindexCandidates(
                targetLangs: targetLangs,
                limit: limit,
                cursorCreatedAtMillis: cursorCreatedAtMillis,
                cursorID: cursorID
            )
        } catch {
            logError("CaptureLibrary fetchOCRReindexCandidates failed: \(error.localizedDescription)", category: "LIB")
            return []
        }
    }

    func updateOCRForReindex(for id: UUID, text: String, langs: [String], notify: Bool) async {
        do {
            try await worker.updateOCR(for: id, text: text, langs: langs, now: Date(), notify: notify)
        } catch {
            logError("CaptureLibrary updateOCRForReindex failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func updateOCRLangsForReindex(for id: UUID, langs: [String], notify: Bool) async {
        do {
            try await worker.updateOCRLangsOnly(for: id, langs: langs, now: Date(), notify: notify)
        } catch {
            logError("CaptureLibrary updateOCRLangsForReindex failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func setPinned(_ pinned: Bool, for id: UUID) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.setPinned(pinned, for: id, now: Date())
        } catch {
            logError("CaptureLibrary setPinned failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func deleteItems(ids: [UUID]) async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.deleteItems(ids: ids)
        } catch {
            logError("CaptureLibrary deleteItems failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func fetchStats() async -> CaptureLibraryStats {
        guard AppSettings.shared.captureLibraryEnabled else { return .empty }
        do {
            return try await worker.fetchStats()
        } catch {
            logError("CaptureLibrary fetchStats failed: \(error.localizedDescription)", category: "LIB")
            return .empty
        }
    }

    func clearAll() async {
        guard AppSettings.shared.captureLibraryEnabled else { return }
        do {
            try await worker.clearAll()
        } catch {
            logError("CaptureLibrary clearAll failed: \(error.localizedDescription)", category: "LIB")
        }
    }

    func runCleanup(policy: CaptureLibraryCleanupPolicy) async -> CaptureLibraryStats {
        guard AppSettings.shared.captureLibraryEnabled else { return .empty }
        do {
            return try await worker.runCleanup(policy: policy, now: Date())
        } catch {
            logError("CaptureLibrary cleanup failed: \(error.localizedDescription)", category: "LIB")
            return .empty
        }
    }

    @discardableResult
    private func enqueue(
        priority: TaskPriority,
        operation: @escaping (CaptureLibraryWorker) async throws -> Void
    ) -> Bool {
        guard acquireJobSlot() else {
            logWarning("CaptureLibrary backlog full; drop job.", category: "LIB")
            return false
        }

        Task.detached(priority: priority) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.releaseJobSlot()
                }
            }
            do {
                try await operation(CaptureLibrary.shared.worker)
            } catch {
                logError("CaptureLibrary job failed: \(error.localizedDescription)", category: "LIB")
            }
        }

        return true
    }

    @discardableResult
    private func enqueueIndexing(
        priority: TaskPriority,
        operation: @escaping (CaptureLibraryWorker) async throws -> Void
    ) -> Bool {
        guard acquireIndexSlot() else {
            logWarning("CaptureLibrary indexing backlog full; drop job.", category: "LIB")
            return false
        }

        Task.detached(priority: priority) { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.releaseIndexSlot()
                }
            }
            do {
                try await operation(CaptureLibrary.shared.worker)
            } catch {
                logError("CaptureLibrary indexing job failed: \(error.localizedDescription)", category: "LIB")
            }
        }

        return true
    }

    private func acquireJobSlot() -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if pendingJobs >= maxPendingJobs { return false }
        pendingJobs += 1
        return true
    }

    private func releaseJobSlot() {
        pendingLock.lock()
        pendingJobs = max(0, pendingJobs - 1)
        pendingLock.unlock()
    }

    private func acquireIndexSlot() -> Bool {
        indexingLock.lock()
        defer { indexingLock.unlock() }
        if pendingIndexJobs >= maxPendingIndexJobs { return false }
        pendingIndexJobs += 1
        return true
    }

    private func releaseIndexSlot() {
        indexingLock.lock()
        pendingIndexJobs = max(0, pendingIndexJobs - 1)
        indexingLock.unlock()
    }
}

fileprivate struct CaptureLibraryAddJob {
    let id: UUID
    let createdAt: Date

    let captureType: CaptureItemCaptureType
    let captureMode: CaptureItemCaptureMode
    let trigger: CaptureItemTrigger

    let appBundleID: String?
    let appName: String?
    let appPID: Int?
    let selectionSize: CGSize

    let externalFilePath: String?

    let cgImage: CGImage
    let storePreview: Bool

    let ocrText: String?
    let ocrLangs: [String]

    let autoOCR: Bool
    let autoOCRPreferredLanguages: [String]
}

actor CaptureLibraryWorker {
    private static let legacyMigrationKey = "captureLibrary.didMigrateLegacyHistory.v1"

    private var fileStore: CaptureLibraryFileStore?
    private var database: CaptureLibraryDatabase?

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .captureLibraryChanged, object: nil)
        }
    }

    func prepareIfNeeded() throws {
        if fileStore == nil {
            let rootURL = try CaptureLibraryFileStore.defaultRootURL()
            fileStore = try CaptureLibraryFileStore(rootURL: rootURL)
        }
        if database == nil {
            guard let fileStore else {
                throw NSError(domain: "CaptureLibraryWorker", code: -1, userInfo: [NSLocalizedDescriptionKey: "FileStore 未初始化"])
            }
            database = try CaptureLibraryDatabase(databaseURL: fileStore.databaseURL)
        }
    }

    fileprivate func addCapture(job: CaptureLibraryAddJob) async throws {
        try prepareIfNeeded()
        guard let fileStore, let database else { return }

        let now = Date()

        let thumb = try fileStore.writeThumbnail(id: job.id, from: job.cgImage)
        let preview: (relativePath: String, pixelSize: CGSize, byteCount: Int)?
        if job.storePreview {
            preview = try fileStore.writePreview(id: job.id, from: job.cgImage)
        } else {
            preview = nil
        }

        let item = CaptureItem(
            id: job.id,
            createdAt: job.createdAt,
            updatedAt: now,
            captureType: job.captureType,
            captureMode: job.captureMode,
            trigger: job.trigger,
            appBundleID: job.appBundleID,
            appName: job.appName,
            appPID: job.appPID,
            selectionSize: job.selectionSize,
            externalFilePath: job.externalFilePath,
            internalThumbPath: thumb.relativePath,
            internalPreviewPath: preview?.relativePath,
            internalOriginalPath: nil,
            thumbSize: thumb.pixelSize,
            previewSize: preview?.pixelSize,
            sha256: nil,
            isPinned: false,
            pinnedAt: nil,
            note: nil,
            tagsCache: "",
            ocrText: job.ocrText,
            ocrLangs: job.ocrLangs,
            ocrUpdatedAt: job.ocrText == nil ? nil : now,
            embeddingModel: nil,
            embeddingDim: nil,
            embedding: nil,
            embeddingSourceHash: nil,
            embeddingUpdatedAt: nil,
            bytesThumb: thumb.byteCount,
            bytesPreview: preview?.byteCount ?? 0,
            bytesOriginal: 0
        )

        let ftsText = CaptureLibraryFTS.makeText(
            appName: item.appName,
            externalFilePath: item.externalFilePath,
            tagsCache: item.tagsCache,
            note: item.note,
            ocrText: item.ocrText
        )

        try await database.insertCapture(item, ftsText: ftsText)
        notifyChanged()

        if job.autoOCR {
            let existingOCR = job.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingOCR.isEmpty {
                do {
                    let text = try await OCRService.recognizeText(
                        in: job.cgImage,
                        imageSize: job.selectionSize,
                        region: nil,
                        preferredLanguages: job.autoOCRPreferredLanguages.isEmpty ? nil : job.autoOCRPreferredLanguages,
                        qos: .utility
                    )
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        try await database.updateOCR(for: job.id, text: trimmed, langs: job.autoOCRPreferredLanguages, now: Date())
                        notifyChanged()
                    }
                } catch {
                    logWarning("CaptureLibrary auto OCR failed: \(error.localizedDescription)", category: "LIB")
                }
            }
        }
    }

    func updateExternalFilePath(for id: UUID, path: String?, now: Date) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateExternalFilePath(for: id, path: path, now: now)
        notifyChanged()
    }

    func fetchItems(query: CaptureLibraryQuery, limit: Int, offset: Int) async throws -> [CaptureItem] {
        try prepareIfNeeded()
        guard let database else { return [] }
        return try await database.fetchPage(limit: limit, offset: offset, query: query)
    }

    func fetchAppGroups() async throws -> [CaptureLibraryAppGroup] {
        try prepareIfNeeded()
        guard let database else { return [] }
        return try await database.fetchAppGroups()
    }

    func fetchTagGroups() async throws -> [CaptureLibraryTagGroup] {
        try prepareIfNeeded()
        guard let database else { return [] }
        return try await database.fetchTagGroups()
    }

    func fetchOCRReindexCandidates(
        targetLangs: String,
        limit: Int,
        cursorCreatedAtMillis: Int64?,
        cursorID: String?
    ) async throws -> [CaptureLibraryOCRReindexCandidate] {
        try prepareIfNeeded()
        guard let database else { return [] }
        return try await database.fetchOCRReindexCandidates(
            targetLangs: targetLangs,
            limit: limit,
            cursorCreatedAtMillis: cursorCreatedAtMillis,
            cursorID: cursorID
        )
    }

    func setTags(_ tags: [String], for id: UUID, now: Date) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.setTags(tags, for: id, now: now)
        notifyChanged()
    }

    func updateNote(for id: UUID, note: String?, now: Date) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateNote(for: id, note: note, now: now)
        notifyChanged()
    }

    func updateOCR(for id: UUID, text: String, langs: [String], now: Date, notify: Bool) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateOCR(for: id, text: text, langs: langs, now: now)
        if notify { notifyChanged() }
    }

    func updateOCRLangsOnly(for id: UUID, langs: [String], now: Date, notify: Bool) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateOCRLangsOnly(for: id, langs: langs, now: now)
        if notify { notifyChanged() }
    }

    func updateEmbedding(
        for id: UUID,
        model: String,
        dim: Int,
        embedding: Data,
        sourceHash: String,
        now: Date
    ) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.updateEmbedding(for: id, model: model, dim: dim, embedding: embedding, sourceHash: sourceHash, now: now)
    }

    func setPinned(_ pinned: Bool, for id: UUID, now: Date) async throws {
        try prepareIfNeeded()
        guard let database else { return }
        try await database.setPinned(pinned, for: id, now: now)
        notifyChanged()
    }

    func deleteItems(ids: [UUID]) async throws {
        try await deleteItemsInternal(ids: ids, notify: true)
    }

    func fetchStats() async throws -> CaptureLibraryStats {
        try prepareIfNeeded()
        guard let database else { return .empty }
        return try await database.fetchStats()
    }

    func clearAll() async throws {
        try prepareIfNeeded()
        guard let fileStore else { return }

        database = nil
        self.fileStore = nil

        if FileManager.default.fileExists(atPath: fileStore.rootURL.path) {
            try FileManager.default.removeItem(at: fileStore.rootURL)
        }

        self.fileStore = try CaptureLibraryFileStore(rootURL: fileStore.rootURL)
        self.database = try CaptureLibraryDatabase(databaseURL: fileStore.databaseURL)
        notifyChanged()
    }

    func runCleanup(policy: CaptureLibraryCleanupPolicy, now: Date) async throws -> CaptureLibraryStats {
        try prepareIfNeeded()
        guard let database, let fileStore else { return .empty }

        var didChange = false
        var stats = try await database.fetchStats()

        let retentionDays = max(0, policy.retentionDays)
        if retentionDays > 0 {
            let cutoff = now.addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))
            let cutoffMillis = Int64(cutoff.timeIntervalSince1970 * 1000)
            let oldIDs = try await database.fetchUnpinnedIDsCreatedBefore(cutoffMillis)
            if !oldIDs.isEmpty {
                try await deleteItemsInternal(ids: oldIDs, notify: false)
                didChange = true
                stats = try await database.fetchStats()
            }
        }

        let maxItems = max(0, policy.maxItems)
        if maxItems > 0, stats.itemCount > maxItems {
            let excess = stats.itemCount - maxItems
            let ids = try await database.fetchUnpinnedOldestIDs(limit: excess)
            if !ids.isEmpty {
                try await deleteItemsInternal(ids: ids, notify: false)
                didChange = true
                stats = try await database.fetchStats()
            }
        }

        let maxBytes = max(0, policy.maxBytes)
        if maxBytes > 0, stats.bytesTotal > maxBytes {
            let previewCandidates = try await database.fetchUnpinnedPreviewCandidates()
            for candidate in previewCandidates where stats.bytesTotal > maxBytes {
                let result = try await database.clearPreview(for: candidate.id, now: now)
                if let path = result.previewPath {
                    fileStore.deleteIfExists(relativePath: path)
                    stats.bytesPreview = max(0, stats.bytesPreview - result.freedBytes)
                    didChange = true
                }
            }

            if stats.bytesTotal > maxBytes {
                while stats.bytesTotal > maxBytes {
                    let ids = try await database.fetchUnpinnedOldestIDs(limit: 50)
                    if ids.isEmpty { break }
                    try await deleteItemsInternal(ids: ids, notify: false)
                    didChange = true
                    stats = try await database.fetchStats()
                }
            }
        }

        if didChange {
            notifyChanged()
        }

        return stats
    }

    private func deleteItemsInternal(ids: [UUID], notify: Bool) async throws {
        guard !ids.isEmpty else { return }
        try prepareIfNeeded()
        guard let database, let fileStore else { return }

        let paths = try await database.deleteItems(ids: ids)
        for path in paths {
            fileStore.deleteIfExists(relativePath: path.thumb)
            fileStore.deleteIfExists(relativePath: path.preview)
            fileStore.deleteIfExists(relativePath: path.original)
        }
        if notify {
            notifyChanged()
        }
    }

    func migrateLegacyHistoryIfNeeded(legacyPaths: [String]) async {
        guard !UserDefaults.standard.bool(forKey: Self.legacyMigrationKey) else { return }

        let paths = legacyPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paths.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.legacyMigrationKey)
            return
        }

        do {
            try prepareIfNeeded()
        } catch {
            logError("Legacy history migration skipped: \(error.localizedDescription)", category: "LIB")
            return
        }

        guard let fileStore, let database else { return }

        for (index, path) in paths.enumerated() {
            do {
                let id = UUID()

                let fileURL = URL(fileURLWithPath: path)
                let createdAt = (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date)
                    ?? Date().addingTimeInterval(TimeInterval(-index * 5))

                let thumbResult: (relativePath: String, pixelSize: CGSize, byteCount: Int)
                if FileManager.default.fileExists(atPath: path),
                   let image = NSImage(contentsOfFile: path),
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    thumbResult = try fileStore.writeThumbnail(id: id, from: cg)
                } else {
                    let data = try CaptureLibraryFileStore.makePlaceholderThumbnailData()
                    let relativePath = "thumbs/\(id.uuidString).jpg"
                    try data.write(to: fileStore.fileURL(forRelativePath: relativePath), options: .atomic)
                    thumbResult = (relativePath: relativePath, pixelSize: CGSize(width: 64, height: 64), byteCount: data.count)
                }

                let item = CaptureItem(
                    id: id,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    captureType: .area,
                    captureMode: .quick,
                    trigger: .menuBar,
                    appBundleID: nil,
                    appName: nil,
                    appPID: nil,
                    selectionSize: nil,
                    externalFilePath: path,
                    internalThumbPath: thumbResult.relativePath,
                    internalPreviewPath: nil,
                    internalOriginalPath: nil,
                    thumbSize: thumbResult.pixelSize,
                    previewSize: nil,
                    sha256: nil,
                    isPinned: false,
                    pinnedAt: nil,
                    note: nil,
                    tagsCache: "",
                    ocrText: nil,
                    ocrLangs: [],
                    ocrUpdatedAt: nil,
                    embeddingModel: nil,
                    embeddingDim: nil,
                    embedding: nil,
                    embeddingSourceHash: nil,
                    embeddingUpdatedAt: nil,
                    bytesThumb: thumbResult.byteCount,
                    bytesPreview: 0,
                    bytesOriginal: 0
                )

                let ftsText = CaptureLibraryFTS.makeText(
                    appName: nil,
                    externalFilePath: path,
                    tagsCache: "",
                    note: nil,
                    ocrText: nil
                )

                do {
                    try await database.insertCapture(item, ftsText: ftsText)
                } catch {
                    logWarning("Legacy history item insert failed: \(fileURL.lastPathComponent)", category: "LIB")
                }
            } catch {
                logWarning("Legacy history item skipped: \(path)", category: "LIB")
            }
        }

        UserDefaults.standard.set(true, forKey: Self.legacyMigrationKey)
        notifyChanged()
    }

}
