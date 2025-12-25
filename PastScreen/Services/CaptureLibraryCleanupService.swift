//
//  CaptureLibraryCleanupService.swift
//  PastScreen
//
//  Periodic cleanup for CaptureLibrary.
//

import Foundation

@MainActor
final class CaptureLibraryCleanupService {
    static let shared = CaptureLibraryCleanupService()

    private var timer: Timer?
    private var isRunning = false

    private let interval: TimeInterval = 6 * 60 * 60

    private init() {}

    func start() {
        guard timer == nil else { return }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.run(reason: "timer") }
        }

        Task { await run(reason: "startup") }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func runNow() {
        Task { await run(reason: "manual") }
    }

    private func run(reason: String) async {
        guard !isRunning else { return }
        guard AppSettings.shared.captureLibraryEnabled else { return }

        isRunning = true
        defer { isRunning = false }

        let settings = AppSettings.shared
        let policy = CaptureLibraryCleanupPolicy(
            retentionDays: settings.captureLibraryRetentionDays,
            maxItems: settings.captureLibraryMaxItems,
            maxBytes: settings.captureLibraryMaxBytes
        )

        _ = await CaptureLibrary.shared.runCleanup(policy: policy)
        settings.captureLibraryLastCleanupAt = Date()

        logInfo("CaptureLibrary cleanup done (\(reason))", category: "LIB")
    }
}

