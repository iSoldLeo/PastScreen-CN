//
//  HotKeyManager.swift
//  Mio
//
//  Owns the global capture-hotkey monitors. Re-evaluates monitor state
//  when the user toggles the hotkey or grants Accessibility permission.
//
//  Hotkey delivery uses a callback (`start(onHotKeyPressed:)`) rather
//  than a NotificationCenter broadcast: the only consumer is
//  `AppDelegate`, so a typed closure is simpler and easier to reason
//  about under strict concurrency.
//

import Foundation
import AppKit
import Combine

@MainActor
final class HotKeyManager {

    static let shared = HotKeyManager()

    // NSEvent monitor handles are typed as `Any` and `AnyCancellable` is
    // not Sendable, but they live entirely inside this @MainActor class
    // and are touched only from MainActor contexts (including
    // `isolated deinit`). No `nonisolated(unsafe)` required.
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var settingsObserver: AnyCancellable?
    private var permissionObserver: AnyCancellable?
    private var onHotKeyPressed: (@MainActor () -> Void)?

    private let hotKeySettings = AppSettings.shared.hotkey
    private let permissionManager = PermissionManager.shared
    private var isRecordingHotKey = false
    private var isReinstalling = false

    private init() {}

    isolated deinit {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        settingsObserver?.cancel()
        permissionObserver?.cancel()
    }

    // MARK: - Public API

    /// Starts monitoring and registers the callback that fires when the
    /// configured hotkey is pressed. Subsequent calls replace the
    /// previous callback and reinstall the monitors.
    func start(onHotKeyPressed: @escaping @MainActor () -> Void) {
        self.onHotKeyPressed = onHotKeyPressed

        if settingsObserver == nil {
            settingsObserver = hotKeySettings.$globalHotkeyEnabled.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reinstallMonitors()
                }
            }
        }
        if permissionObserver == nil {
            permissionObserver = permissionManager.$accessibilityStatus.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reinstallMonitors()
                }
            }
        }

        reinstallMonitors()
    }

    /// Stops listening for the global hotkey.
    func stop() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    /// Briefly disables hotkey matching while the user records a new
    /// shortcut in Settings, so the in-progress key combination does not
    /// trigger a screenshot.
    func setRecordingHotKey(_ recording: Bool) {
        isRecordingHotKey = recording
    }

    // MARK: - Private

    private func reinstallMonitors() {
        // Reentrancy guard: prevent double-installation when multiple
        // observers fire in the same tick (e.g. settings change +
        // permission grant).
        guard !isReinstalling else { return }
        isReinstalling = true
        defer { isReinstalling = false }

        stop()

        guard hotKeySettings.globalHotkeyEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        globalEventMonitor = Self.installGlobalMonitor { [weak self] keyCode, modifierFlags, characters in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.handleHotKeyValues(keyCode: keyCode, modifierFlags: modifierFlags, characters: characters)
            }
        }

        localEventMonitor = Self.installLocalMonitor { [weak self] keyCode, modifierFlags, characters in
            // SAFETY: addLocalMonitorForEvents always delivers on the
            // main thread, but the closure is synchronous and must
            // return NSEvent? immediately, so `await` is not an option.
            // `assumeIsolated` is the documented escape hatch.
            return MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleHotKeyValues(keyCode: keyCode, modifierFlags: modifierFlags, characters: characters)
            }
        }
    }

    /// nonisolated so NSEvent (non-Sendable) never crosses the MainActor
    /// boundary; only Sendable values flow out of the closure.
    private nonisolated static func installGlobalMonitor(
        handler: @escaping @Sendable (UInt16, NSEvent.ModifierFlags, String?) -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handler(event.keyCode, event.modifierFlags, event.charactersIgnoringModifiers)
        }
    }

    /// Returns `true` when the event was consumed (and should be
    /// swallowed); the local monitor uses this to suppress the normal
    /// app keystroke after a hotkey match.
    private nonisolated static func installLocalMonitor(
        handler: @escaping @Sendable (UInt16, NSEvent.ModifierFlags, String?) -> Bool
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = handler(event.keyCode, event.modifierFlags, event.charactersIgnoringModifiers)
            return handled ? nil : event
        }
    }

    @discardableResult
    private func handleHotKeyValues(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard !isRecordingHotKey else { return false }

        let hotkey = hotKeySettings.globalHotkey
        let requiredModifiers = hotkey.modifierFlags
        let eventModifiers = HotKey.normalizedModifiers(modifierFlags)

        let matchesModifiers = eventModifiers == requiredModifiers
        let matchesKeyCode = keyCode == hotkey.keyCode
        let matchesCharacters: Bool = {
            guard let expected = hotkey.characters?.lowercased(),
                  let actual = characters?.lowercased() else {
                return false
            }
            return expected == actual
        }()

        if matchesModifiers && (matchesKeyCode || matchesCharacters) {
            onHotKeyPressed?()
            return true
        }
        return false
    }
}
