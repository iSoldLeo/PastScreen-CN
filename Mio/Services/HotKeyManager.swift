//
//  HotKeyManager.swift
//  Mio
//
//  Created by Eric COLOGNI on 2025-11-20.
//
//  Manages the global hotkey for capturing screenshots.
//

import Foundation
// TODO: Remove @preconcurrency once Apple marks NSEvent as Sendable.
@preconcurrency import AppKit  // NSEvent 未标记 Sendable，但在 addGlobalMonitorForEvents 回调中需要跨隔离域传递
// TODO: Remove @preconcurrency once Apple marks Combine types as Sendable.
@preconcurrency import Combine  // AnyCancellable 未标记 Sendable

@MainActor
class HotKeyManager {

    static let shared = HotKeyManager()

    // nonisolated(unsafe): NSEvent monitor handles are typed as Any (not Sendable).
    // They are created on MainActor (startMonitoring) and only cleaned up in deinit.
    // Safe because: (1) writes only happen on MainActor, (2) reads in deinit happen
    // after all references released, (3) NSEvent.removeMonitor is thread-safe.
    // TODO: Replace with typed wrapper once Apple provides Sendable monitor token API.
    private nonisolated(unsafe) var globalEventMonitor: Any?
    private nonisolated(unsafe) var localEventMonitor: Any?
    private let hotKeySettings = AppSettings.shared.hotkey
    private let permissionManager = PermissionManager.shared
    // nonisolated(unsafe): AnyCancellable is not marked Sendable by Apple.
    // Set once in init (MainActor) and only cancelled in deinit.
    // TODO: Remove once Combine types are marked Sendable.
    private nonisolated(unsafe) var settingsObserver: AnyCancellable?
    private nonisolated(unsafe) var permissionObserver: AnyCancellable?
    private var isRecordingHotKey = false
    private var isStartingMonitoring = false

    private init() {
        // Observe changes to the hotkey enabled setting.
        // This allows enabling/disabling the hotkey from the Settings window
        // without needing to restart the app.
        settingsObserver = hotKeySettings.$globalHotkeyEnabled.sink { [weak self] enabled in
            Task { [weak self] in
                guard let self else { return }
                if enabled {
                    self.startMonitoring()
                } else {
                    self.stopMonitoring()
                }
            }
        }

        // Restart monitoring automatically once Accessibility permission is granted
        permissionObserver = permissionManager.$accessibilityStatus
            .sink { [weak self] status in
                Task { [weak self] in
                    guard let self else { return }
                    if status == .authorized {
                        self.startMonitoring()
                    } else {
                        self.stopMonitoring()
                    }
                }
            }
    }

    nonisolated deinit {
        // deinit is nonisolated — only do minimal cleanup here.
        // NSEvent monitors are removed via removeMonitor which is safe to call from any thread.
        // We access the stored monitor references directly (nonisolated access to stored properties is allowed in deinit).
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        settingsObserver?.cancel()
        permissionObserver?.cancel()
    }

    /// Starts listening for the global hotkey if it's enabled in settings.
    func startMonitoring() {
        // Reentrancy guard: prevent double-installation when multiple observers
        // fire simultaneously (e.g. settings change + permission grant).
        guard !isStartingMonitoring else { return }
        isStartingMonitoring = true
        defer { isStartingMonitoring = false }

        // Ensure we don't create multiple monitors by stopping any existing ones.
        stopMonitoring()

        guard hotKeySettings.globalHotkeyEnabled else {
            return
        }

        // The hotkey requires Accessibility permissions. We check for them here but
        // do not prompt the user. The onboarding flow is responsible for requesting permissions.
        guard AXIsProcessTrusted() else {
            return
        }

        globalEventMonitor = Self.installGlobalMonitor { [weak self] keyCode, modifierFlags, characters in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.handleHotKeyValues(keyCode: keyCode, modifierFlags: modifierFlags, characters: characters)
            }
        }

        localEventMonitor = Self.installLocalMonitor { [weak self] keyCode, modifierFlags, characters in
            // SAFETY: addLocalMonitorForEvents always delivers on the main thread.
            // We use assumeIsolated because the callback is synchronous and must return NSEvent?.
            return MainActor.assumeIsolated {
                guard let self = self else { return false }
                return self.handleHotKeyValues(keyCode: keyCode, modifierFlags: modifierFlags, characters: characters)
            }
        }
    }

    // MARK: - nonisolated monitor installation
    // These are nonisolated to avoid NSEvent (non-Sendable) crossing @MainActor boundary.
    // NSEvent values are extracted inside the closure and only Sendable values are passed out.

    /// Installs a global key-down monitor. The callback receives extracted Sendable values only.
    private nonisolated static func installGlobalMonitor(
        handler: @escaping @Sendable (UInt16, NSEvent.ModifierFlags, String?) -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handler(event.keyCode, event.modifierFlags, event.charactersIgnoringModifiers)
        }
    }

    /// Installs a local key-down monitor. The callback returns true if the event was handled (should be swallowed).
    private nonisolated static func installLocalMonitor(
        handler: @escaping @Sendable (UInt16, NSEvent.ModifierFlags, String?) -> Bool
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = handler(event.keyCode, event.modifierFlags, event.charactersIgnoringModifiers)
            return handled ? nil : event
        }
    }

    /// Stops listening for the global hotkey.
    func stopMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    func setRecordingHotKey(_ recording: Bool) {
        isRecordingHotKey = recording
    }

    @discardableResult
    private func handleHotKeyValues(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard !isRecordingHotKey else { return false }

        // Check for regular screenshot hotkey
        let hotkey = hotKeySettings.globalHotkey
        let requiredModifiers = hotkey.modifierFlags
        let eventModifiers = HotKey.normalizedModifiers(modifierFlags)

        let matchesModifiers = eventModifiers == requiredModifiers
        let matchesKeyCode = keyCode == hotkey.keyCode
        let matchesCharacters = {
            guard let expected = hotkey.characters?.lowercased(),
                  let actual = characters?.lowercased() else {
                return false
            }
            return expected == actual
        }()

        if matchesModifiers && (matchesKeyCode || matchesCharacters) {
            // Post a notification to decouple the hotkey detection from the action.
            // The AppDelegate will listen for this notification to trigger a screenshot.
            NotificationCenter.default.post(name: .hotKeyPressed, object: nil)
            return true
        }

        return false
    }
}
