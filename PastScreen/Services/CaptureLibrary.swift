//
//  CaptureLibrary.swift
//  PastScreen
//
//  Lightweight local capture library: metadata in SQLite + assets on disk.
//

import AppKit
import CryptoKit
import Foundation
import NaturalLanguage

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

    @MainActor
    func copyImageToClipboard(item: CaptureItem) {
        guard let result = bestImageURL(for: item, allowThumbnailFallback: true) else {
            DynamicIslandManager.shared.show(message: "无可复制图片", duration: 2.0, style: .failure)
            return
        }

        let url = result.url
        guard let image = NSImage(contentsOfFile: url.path) else {
            DynamicIslandManager.shared.show(message: "读取图片失败", duration: 2.0, style: .failure)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setString(url.path, forType: .string)

        if AppSettings.shared.playSoundOnCapture {
            NSSound(named: "Pop")?.play()
        }

        if result.isThumbnail {
            DynamicIslandManager.shared.show(message: "已复制（缩略图）", duration: 1.6)
        } else {
            DynamicIslandManager.shared.show(message: "已复制", duration: 1.5)
        }
    }

    @MainActor
    func copyPathToClipboard(item: CaptureItem) {
        guard let url = bestAnyURL(for: item) else {
            DynamicIslandManager.shared.show(message: "无可复制路径", duration: 2.0, style: .failure)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        DynamicIslandManager.shared.show(message: "路径已复制", duration: 1.5)
    }

    @MainActor
    func revealInFinder(item: CaptureItem) {
        guard let url = bestAnyURL(for: item) else {
            DynamicIslandManager.shared.show(message: "找不到文件", duration: 2.0, style: .failure)
            return
        }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    private func bestImageURL(for item: CaptureItem, allowThumbnailFallback: Bool) -> (url: URL, isThumbnail: Bool)? {
        if let url = bestAnyURL(for: item, requireCopyableImage: true) {
            return (url: url, isThumbnail: false)
        }
        guard allowThumbnailFallback else { return nil }
        guard let url = resolveInternalURL(item.internalThumbPath) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url: url, isThumbnail: true)
    }

    private func bestAnyURL(for item: CaptureItem, requireCopyableImage: Bool = false) -> URL? {
        let candidates: [URL] = [
            resolveInternalURL(item.internalOriginalPath),
            resolveInternalURL(item.internalPreviewPath),
            item.externalFileURL,
            requireCopyableImage ? nil : resolveInternalURL(item.internalThumbPath)
        ].compactMap { $0 }

        let fileManager = FileManager.default
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private func resolveInternalURL(_ relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        guard let root = try? CaptureLibraryFileStore.defaultRootURL() else { return nil }
        return root.appendingPathComponent(relativePath, isDirectory: false)
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
            defer { self?.releaseJobSlot() }
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
            defer { self?.releaseIndexSlot() }
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

// MARK: - Semantic Search (M3, Experimental)

actor CaptureLibrarySemanticSearchService {
    static let shared = CaptureLibrarySemanticSearchService()

    private struct Config {
        var embedding: NLEmbedding
        var modelName: String
        var dim: Int
        var isSentence: Bool
        var language: NLLanguage
    }

    private var cachedConfigs: [String: Config] = [:]

    func rerank(items: [CaptureItem], queryText: String, includeFTSWeight: Bool = true) async -> [CaptureItem] {
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, items.count > 1 else { return items }

        guard let config = resolveConfig(for: trimmedQuery) else { return items }
        guard let queryVector = embed(text: trimmedQuery, config: config) else { return items }

        var scored: [(item: CaptureItem, index: Int, finalScore: Double)] = []
        scored.reserveCapacity(items.count)

        var updates: [(id: UUID, embedding: Data, sourceHash: String)] = []

        let n = max(1, items.count - 1)
        for (index, item) in items.enumerated() {
            let ftsScore: Double = includeFTSWeight ? (1.0 - (Double(index) / Double(n))) : 0.0
            let semanticText = Self.semanticText(for: item)
            let sourceHash = Self.sha256Hex(semanticText)

            let itemVector: [Float]?
            if let existing = item.embedding,
               item.embeddingModel == config.modelName,
               item.embeddingDim == config.dim,
               item.embeddingSourceHash == sourceHash,
               let decoded = Self.decodeEmbedding(existing, dim: config.dim) {
                itemVector = decoded
            } else {
                itemVector = embed(text: semanticText, config: config)
                if let itemVector {
                    updates.append((id: item.id, embedding: Self.encodeEmbedding(itemVector), sourceHash: sourceHash))
                }
            }

            let semanticScore: Double
            if let itemVector {
                let cosine = Double(Self.dot(queryVector, itemVector))
                let normalized = min(1.0, max(0.0, (cosine + 1.0) / 2.0))
                semanticScore = normalized
            } else {
                semanticScore = 0
            }

            let finalScore: Double
            if includeFTSWeight {
                finalScore = 0.6 * ftsScore + 0.4 * semanticScore
            } else {
                finalScore = semanticScore
            }
            scored.append((item: item, index: index, finalScore: finalScore))
        }

        let reranked = scored.sorted { lhs, rhs in
            if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
            if lhs.item.createdAt != rhs.item.createdAt { return lhs.item.createdAt > rhs.item.createdAt }
            return lhs.index < rhs.index
        }.map { $0.item }

        scheduleEmbeddingWrites(updates: updates, config: config)
        return reranked
    }

    private func resolveConfig(for query: String) -> Config? {
        let candidates = Self.preferredLanguages(for: query)

        for lang in candidates {
            let cacheKey = "sentence:\(lang.rawValue)"
            if let cached = cachedConfigs[cacheKey] {
                return cached
            }
            if let embedding = NLEmbedding.sentenceEmbedding(for: lang) {
                let config = Config(
                    embedding: embedding,
                    modelName: "nl_sentence_\(lang.rawValue)",
                    dim: embedding.dimension,
                    isSentence: true,
                    language: lang
                )
                cachedConfigs[cacheKey] = config
                return config
            }
        }

        for lang in candidates {
            let cacheKey = "word:\(lang.rawValue)"
            if let cached = cachedConfigs[cacheKey] {
                return cached
            }
            if let embedding = NLEmbedding.wordEmbedding(for: lang) {
                let config = Config(
                    embedding: embedding,
                    modelName: "nl_word_\(lang.rawValue)",
                    dim: embedding.dimension,
                    isSentence: false,
                    language: lang
                )
                cachedConfigs[cacheKey] = config
                return config
            }
        }

        return nil
    }

    private func embed(text: String, config: Config) -> [Float]? {
        if config.isSentence {
            guard let vec = config.embedding.vector(for: text) else { return nil }
            guard vec.count == config.dim else { return nil }
            let floats = vec.map { Float($0) }
            return Self.normalized(floats)
        }

        let tokens = Self.tokenize(text: text, maxTokens: 256)
        guard !tokens.isEmpty else { return nil }

        var sum = [Double](repeating: 0, count: config.dim)
        var count = 0

        for token in tokens {
            guard let vec = config.embedding.vector(for: token), vec.count == config.dim else { continue }
            for i in 0..<config.dim {
                sum[i] += vec[i]
            }
            count += 1
        }

        guard count > 0 else { return nil }

        var out = [Float](repeating: 0, count: config.dim)
        let inv = 1.0 / Double(count)
        for i in 0..<config.dim {
            out[i] = Float(sum[i] * inv)
        }

        return Self.normalized(out)
    }

    private func scheduleEmbeddingWrites(updates: [(id: UUID, embedding: Data, sourceHash: String)], config: Config) {
        guard !updates.isEmpty else { return }
        let limited = Array(updates.prefix(40))
        Task.detached(priority: .background) {
            for update in limited {
                await CaptureLibrary.shared.updateEmbedding(
                    for: update.id,
                    model: config.modelName,
                    dim: config.dim,
                    embedding: update.embedding,
                    sourceHash: update.sourceHash
                )
            }
        }
    }

    private static func preferredLanguages(for text: String) -> [NLLanguage] {
        var candidates: [NLLanguage] = []

        if let dominant = NLLanguageRecognizer.dominantLanguage(for: text) {
            candidates.append(dominant)
        }

        for identifier in Locale.preferredLanguages {
            let base = identifier.split(separator: "-").first.map(String.init) ?? identifier
            candidates.append(NLLanguage(rawValue: base))
        }

        candidates.append(.simplifiedChinese)
        candidates.append(.traditionalChinese)
        candidates.append(.english)

        var unique: [NLLanguage] = []
        var seen = Set<NLLanguage>()
        for language in candidates where seen.insert(language).inserted {
            unique.append(language)
        }
        return unique
    }

    private static func tokenize(text: String, maxTokens: Int) -> [String] {
        let lowered = text.lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = lowered

        var out: [String] = []
        out.reserveCapacity(min(64, maxTokens))

        tokenizer.enumerateTokens(in: lowered.startIndex..<lowered.endIndex) { range, _ in
            if out.count >= maxTokens { return false }
            let token = String(lowered[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return true }
            guard token.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) else {
                return true
            }
            out.append(token)
            return true
        }

        return out
    }

    private static func semanticText(for item: CaptureItem) -> String {
        var parts: [String] = []
        if let appName = item.appName, !appName.isEmpty { parts.append(appName) }
        if !item.tagsCache.isEmpty { parts.append(item.tagsCache) }
        if let note = item.note, !note.isEmpty { parts.append(note) }
        if let external = item.externalFilePath, !external.isEmpty {
            parts.append(URL(fileURLWithPath: external).lastPathComponent)
        }
        if let ocr = item.ocrText, !ocr.isEmpty {
            parts.append(String(ocr.prefix(2_000)))
        }
        return parts.joined(separator: " ")
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeEmbedding(_ vector: [Float]) -> Data {
        var copy = vector
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    private static func decodeEmbedding(_ data: Data, dim: Int) -> [Float]? {
        let expected = dim * MemoryLayout<Float>.size
        guard data.count == expected else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        var sum: Float = 0
        for i in 0..<count {
            sum += a[i] * b[i]
        }
        return sum
    }

    private static func normalized(_ v: [Float]) -> [Float]? {
        var sum: Double = 0
        for x in v {
            sum += Double(x * x)
        }
        let norm = sqrt(sum)
        guard norm > 0 else { return nil }
        let inv = Float(1.0 / norm)
        return v.map { $0 * inv }
    }
}
