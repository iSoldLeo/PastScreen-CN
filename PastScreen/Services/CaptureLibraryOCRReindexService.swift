//
//  CaptureLibraryOCRReindexService.swift
//  PastScreen
//
//  Rebuild OCR index in background when OCR languages change.
//

import AppKit
import Combine
import Foundation

@MainActor
final class CaptureLibraryOCRReindexService {
    static let shared = CaptureLibraryOCRReindexService()

    private struct LanguageInput: Equatable {
        let preferredLanguages: [String]
        let key: String
    }

    private enum DefaultsKeys {
        static let appliedLangsKey = "captureLibrary.ocrReindex.appliedLangsKey.v1"
        static let targetLangsKey = "captureLibrary.ocrReindex.targetLangsKey.v1"
        static let cursorCreatedAtMillis = "captureLibrary.ocrReindex.cursorCreatedAtMillis.v1"
        static let cursorID = "captureLibrary.ocrReindex.cursorID.v1"
        static let lastRunAtMillis = "captureLibrary.ocrReindex.lastRunAtMillis.v1"
    }

    private var languageObserver: AnyCancellable?
    private var enabledObserver: AnyCancellable?

    private var currentTask: Task<Void, Never>?
    private var currentTaskTargetKey: String?

    private init() {}

    func start() {
        guard languageObserver == nil, enabledObserver == nil else { return }

        let settings = AppSettings.shared

        enabledObserver = settings.$captureLibraryEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.scheduleStartupIfNeeded()
                } else {
                    self.cancel(reason: "disabled")
                }
            }

        languageObserver = settings.$ocrRecognitionLanguages
            .map { raw in
                let preferred = Self.normalizedPreferredLanguages(raw)
                return LanguageInput(preferredLanguages: preferred, key: Self.langsKey(for: preferred))
            }
            .debounce(for: .milliseconds(650), scheduler: DispatchQueue.main)
            .removeDuplicates(by: { $0.key == $1.key })
            .sink { [weak self] input in
                self?.scheduleReindex(
                    targetKey: input.key,
                    preferredLanguages: input.preferredLanguages,
                    resetCursor: true,
                    reason: "languages_changed"
                )
            }

        scheduleStartupIfNeeded()
    }

    func stop() {
        cancel(reason: "stop")
        languageObserver?.cancel()
        enabledObserver?.cancel()
        languageObserver = nil
        enabledObserver = nil
    }

    private func scheduleStartupIfNeeded() {
        guard AppSettings.shared.captureLibraryEnabled else { return }

        let preferred = Self.normalizedPreferredLanguages(AppSettings.shared.ocrRecognitionLanguages)
        let key = Self.langsKey(for: preferred)

        let defaults = UserDefaults.standard
        let applied = defaults.string(forKey: DefaultsKeys.appliedLangsKey) ?? ""
        let hasCursor = defaults.object(forKey: DefaultsKeys.cursorCreatedAtMillis) != nil || defaults.string(forKey: DefaultsKeys.cursorID) != nil

        guard hasCursor || applied != key else { return }

        scheduleReindex(targetKey: key, preferredLanguages: preferred, resetCursor: false, reason: "startup")
    }

    private func cancel(reason: String) {
        currentTask?.cancel()
        currentTask = nil
        currentTaskTargetKey = nil
        logInfo("CaptureLibrary OCR reindex canceled (\(reason))", category: "LIB")
    }

    private func scheduleReindex(
        targetKey: String,
        preferredLanguages: [String],
        resetCursor: Bool,
        reason: String
    ) {
        guard AppSettings.shared.captureLibraryEnabled else { return }

        if currentTaskTargetKey == targetKey, currentTask != nil {
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(targetKey, forKey: DefaultsKeys.targetLangsKey)
        if resetCursor {
            defaults.removeObject(forKey: DefaultsKeys.cursorCreatedAtMillis)
            defaults.removeObject(forKey: DefaultsKeys.cursorID)
        }

        cancel(reason: "restart")

        currentTaskTargetKey = targetKey
        logInfo("CaptureLibrary OCR reindex scheduled (\(reason))", category: "LIB")

        currentTask = Task.detached(priority: .background) {
            await Self.runReindexLoop(targetKey: targetKey, preferredLanguages: preferredLanguages)
        }
    }

    private static func runReindexLoop(targetKey: String, preferredLanguages: [String]) async {
        let defaults = UserDefaults.standard
        let targetSet = Set(targetKey.split(whereSeparator: \.isWhitespace).map(String.init))

        let rootURL = try? CaptureLibraryFileStore.defaultRootURL()

        var cursorCreatedAtMillis: Int64? = readInt64(defaults, key: DefaultsKeys.cursorCreatedAtMillis)
        var cursorID: String? = defaults.string(forKey: DefaultsKeys.cursorID)

        var processed = 0
        let batchSize = 18

        while !Task.isCancelled {
            guard defaults.string(forKey: DefaultsKeys.targetLangsKey) == targetKey else {
                return
            }

            let candidates = await CaptureLibrary.shared.fetchOCRReindexCandidates(
                targetLangs: targetKey,
                limit: batchSize,
                cursorCreatedAtMillis: cursorCreatedAtMillis,
                cursorID: cursorID
            )

            if candidates.isEmpty {
                defaults.set(targetKey, forKey: DefaultsKeys.appliedLangsKey)
                defaults.removeObject(forKey: DefaultsKeys.cursorCreatedAtMillis)
                defaults.removeObject(forKey: DefaultsKeys.cursorID)
                defaults.set(NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000)), forKey: DefaultsKeys.lastRunAtMillis)

                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .captureLibraryChanged, object: nil)
                }

                logInfo("CaptureLibrary OCR reindex done", category: "LIB")
                return
            }

            for candidate in candidates {
                guard !Task.isCancelled else { return }
                guard defaults.string(forKey: DefaultsKeys.targetLangsKey) == targetKey else { return }

                let existingLangSet = langSet(from: candidate.ocrLangs)
                if existingLangSet == targetSet {
                    await CaptureLibrary.shared.updateOCRLangsForReindex(for: candidate.id, langs: preferredLanguages, notify: false)
                } else {
                    let url = bestImageURL(for: candidate, rootURL: rootURL)
                    if let url, FileManager.default.fileExists(atPath: url.path) {
                        let cgImage = OCRService.loadCGImage(from: url)
                            ?? NSImage(contentsOfFile: url.path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                        guard let cgImage else {
                            await CaptureLibrary.shared.updateOCRLangsForReindex(for: candidate.id, langs: preferredLanguages, notify: false)
                            continue
                        }
                        do {
                            let text = try await OCRService.recognizeText(
                                in: cgImage,
                                imageSize: CGSize(width: cgImage.width, height: cgImage.height),
                                region: nil,
                                preferredLanguages: preferredLanguages.isEmpty ? nil : preferredLanguages,
                                qos: .utility
                            )
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty {
                                await CaptureLibrary.shared.updateOCRLangsForReindex(for: candidate.id, langs: preferredLanguages, notify: false)
                            } else {
                                await CaptureLibrary.shared.updateOCRForReindex(for: candidate.id, text: trimmed, langs: preferredLanguages, notify: false)
                            }
                        } catch {
                            await CaptureLibrary.shared.updateOCRLangsForReindex(for: candidate.id, langs: preferredLanguages, notify: false)
                        }
                    } else {
                        await CaptureLibrary.shared.updateOCRLangsForReindex(for: candidate.id, langs: preferredLanguages, notify: false)
                    }
                }

                cursorCreatedAtMillis = candidate.createdAtMillis
                cursorID = candidate.id.uuidString
                writeInt64(defaults, key: DefaultsKeys.cursorCreatedAtMillis, value: cursorCreatedAtMillis)
                defaults.set(cursorID, forKey: DefaultsKeys.cursorID)

                processed += 1
                if processed % 24 == 0 {
                    try? await Task.sleep(nanoseconds: 160_000_000)
                } else {
                    await Task.yield()
                }
            }
        }
    }

    private static func normalizedPreferredLanguages(_ raw: [String]) -> [String] {
        let cleaned = raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var out: [String] = []
        for lang in cleaned where seen.insert(lang).inserted {
            out.append(lang)
        }
        return out
    }

    private static func langsKey(for preferredLanguages: [String]) -> String {
        let sorted = preferredLanguages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        return sorted.joined(separator: " ")
    }

    private static func langSet(from stored: String?) -> Set<String> {
        let parts = (stored ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(parts)
    }

    private static func bestImageURL(for candidate: CaptureLibraryOCRReindexCandidate, rootURL: URL?) -> URL? {
        var urls: [URL] = []
        urls.reserveCapacity(4)

        if let rootURL {
            if let path = candidate.internalOriginalPath, !path.isEmpty {
                urls.append(rootURL.appendingPathComponent(path, isDirectory: false))
            }
            if let path = candidate.internalPreviewPath, !path.isEmpty {
                urls.append(rootURL.appendingPathComponent(path, isDirectory: false))
            }
        }

        if let external = candidate.externalFilePath, !external.isEmpty {
            urls.append(URL(fileURLWithPath: external))
        }

        if let rootURL {
            let path = candidate.internalThumbPath
            if !path.isEmpty {
                urls.append(rootURL.appendingPathComponent(path, isDirectory: false))
            }
        }

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private static func readInt64(_ defaults: UserDefaults, key: String) -> Int64? {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return nil }
        return value.int64Value
    }

    private static func writeInt64(_ defaults: UserDefaults, key: String, value: Int64?) {
        if let value {
            defaults.set(NSNumber(value: value), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
