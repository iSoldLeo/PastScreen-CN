//
//  LaunchAtLoginManager.swift
//  Mio
//
//  Launch at login functionality using ServiceManagement.
//
//  `SMAppService.register()` / `unregister()` perform a launchd
//  registration round-trip that can block for several to tens of
//  milliseconds. To keep `@MainActor` setters responsive we expose
//  an async `setEnabled(_:)` that hops to a utility-priority detached
//  task; the `isEnabled` getter remains synchronous (cheap status read).
//

import Foundation
import ServiceManagement

@MainActor
class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private init() {}

    /// Returns the current registration state. Cheap status read, safe on
    /// the main actor.
    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            // Fallback for older macOS versions (not applicable for macOS 14+ requirement)
            return false
        }
    }

    /// Enable or disable launch at login.
    ///
    /// The actual `SMAppService` call runs on a detached utility-priority
    /// task to avoid blocking the main actor while launchd processes the
    /// registration. The function returns once launchd responds (or the
    /// call throws), so callers awaiting the result observe a consistent
    /// post-state.
    ///
    /// Bool is Sendable, so passing `enabled` across the detached task
    /// boundary is safe.
    func setEnabled(_ enabled: Bool) async {
        guard #available(macOS 13.0, *) else { return }

        // SAFETY: The detached task captures only `enabled` (Sendable) and
        // touches no main-actor state. The owning actor's lifetime is the
        // process lifetime (singleton); cancellation is irrelevant — the
        // call must complete or fail to remain consistent with launchd.
        await Task.detached(priority: .utility) {
            do {
                let service = SMAppService.mainApp
                if enabled {
                    if service.status == .enabled {
                        NSLog("✅ [LAUNCH] Already enabled")
                    } else {
                        try service.register()
                        NSLog("✅ [LAUNCH] Enabled successfully")
                    }
                } else {
                    if service.status == .notRegistered {
                        NSLog("✅ [LAUNCH] Already disabled")
                    } else {
                        try service.unregister()
                        NSLog("✅ [LAUNCH] Disabled successfully")
                    }
                }
            } catch {
                NSLog("❌ [LAUNCH] Failed to \(enabled ? "enable" : "disable"): \(error.localizedDescription)")
            }
        }.value
    }
}
