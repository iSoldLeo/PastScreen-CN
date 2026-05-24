//
//  HotKeyManager.swift
//  Mio
//
//  Owns the global capture-hotkey registration via Carbon's
//  `RegisterEventHotKey` API. Two independent hotkeys (window capture /
//  full-screen) are registered simultaneously; either can be in
//  `HotKey.unset` state to disable matching for that hotkey.
//
//  Why Carbon, not NSEvent.addGlobalMonitorForEvents?
//
//    - NSEvent global monitor delivers a SUBSET of system keystrokes.
//      Modifier-less function keys (F5 Dictation, F3 Mission Control)
//      and other system-reserved combinations are consumed before the
//      monitor sees them.
//    - NSEvent global monitor requires Accessibility permission. Carbon
//      RegisterEventHotKey does not — it registers at the application
//      event target level which is permission-free.
//    - Every battle-tested macOS hotkey library (Sindre's
//      KeyboardShortcuts, Sam Soffes' HotKey, MASShortcut) uses Carbon.
//      Apple has signaled no removal as of macOS 26.
//
//  Caveats Mio inherits from Carbon:
//    - System-reserved single-press hotkeys (F5 Dictation by default)
//      may still fire the system action FIRST. The user fixes this in
//      System Settings → Keyboard by toggling "Use F1, F2, etc. as
//      standard function keys", or by disabling the conflicting
//      system shortcut.
//    - The Carbon callback is `@convention(c)` so it cannot capture
//      Swift context; we hop to MainActor via `Task { @MainActor in }`
//      and read the hotkey id (Sendable UInt32) inside.
//

import Foundation
import AppKit
import Combine
import Carbon.HIToolbox

@MainActor
final class HotKeyManager {

    /// Discriminator for which configured hotkey was matched. The
    /// `carbonId` is the value Carbon stores in `EventHotKeyID.id` and
    /// is what the C callback sends back to us.
    enum Match: Sendable {
        case windowCapture
        case fullScreen

        var carbonId: UInt32 {
            switch self {
            case .windowCapture: return 1
            case .fullScreen: return 2
            }
        }

        init?(carbonId: UInt32) {
            switch carbonId {
            case Match.windowCapture.carbonId: self = .windowCapture
            case Match.fullScreen.carbonId: self = .fullScreen
            default: return nil
            }
        }
    }

    static let shared = HotKeyManager()

    /// 4-byte signature distinguishing Mio's hotkeys from any other app
    /// that might register Carbon hotkeys via the same event target.
    /// 'Mio0' as a four-char-code.
    private static let signature: OSType = {
        let bytes: [UInt8] = [0x4D, 0x69, 0x6F, 0x30] // 'M', 'i', 'o', '0'
        return UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }()

    private var hotKeyRefs: [Match: EventHotKeyRef] = [:]
    private var carbonEventHandler: EventHandlerRef?
    private var windowHotkeyObserver: AnyCancellable?
    private var fullScreenHotkeyObserver: AnyCancellable?
    private var onHotKey: (@MainActor (Match) -> Void)?

    private let hotKeySettings = AppSettings.shared.hotkey
    private var isRecordingHotKey = false
    private var isReinstalling = false

    private init() {}

    isolated deinit {
        unregisterAllHotKeys()
        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
        }
        windowHotkeyObserver?.cancel()
        fullScreenHotkeyObserver?.cancel()
    }

    // MARK: - Public API

    /// Starts hotkey monitoring and registers the callback that fires
    /// when either configured hotkey is pressed system-wide. Subsequent
    /// calls replace the previous callback and re-register both hotkeys.
    func start(onHotKey: @escaping @MainActor (Match) -> Void) {
        self.onHotKey = onHotKey

        if windowHotkeyObserver == nil {
            windowHotkeyObserver = hotKeySettings.$windowCaptureHotkey.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reinstallHotKeys()
                }
            }
        }
        if fullScreenHotkeyObserver == nil {
            fullScreenHotkeyObserver = hotKeySettings.$fullScreenHotkey.sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reinstallHotKeys()
                }
            }
        }

        installCarbonEventHandler()
        reinstallHotKeys()
    }

    /// Stops listening for hotkeys (unregisters all Carbon hotkeys).
    /// The event handler stays installed so a later `start` can
    /// re-register without going through `InstallEventHandler` again.
    func stop() {
        unregisterAllHotKeys()
    }

    /// Briefly suppresses hotkey dispatch while the user records a new
    /// shortcut in Settings, so the in-progress key combination cannot
    /// fire the production handler. We additionally unregister the
    /// Carbon hotkeys during recording — Carbon eats the keystroke
    /// before the recorder's NSEvent local monitor sees it, so the
    /// recording would otherwise never observe a conflicting key.
    func setRecordingHotKey(_ recording: Bool) {
        let changed = isRecordingHotKey != recording
        isRecordingHotKey = recording
        if changed {
            reinstallHotKeys()
        }
    }

    // MARK: - Private

    private func installCarbonEventHandler() {
        guard carbonEventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The C callback cannot capture Swift context. It reads the
        // hotkey id (Sendable UInt32) and hops to MainActor via Task.
        // Reading `HotKeyManager.shared` inside the Task runs on
        // MainActor — that's where the @MainActor isolation requirement
        // is satisfied.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                guard let eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let id = hotKeyID.id
                Task { @MainActor in
                    HotKeyManager.shared.dispatchHotKeyId(id)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &carbonEventHandler
        )
    }

    private func reinstallHotKeys() {
        // Reentrancy guard: prevent double-registration when both
        // settings observers fire in the same tick.
        guard !isReinstalling else { return }
        isReinstalling = true
        defer { isReinstalling = false }

        unregisterAllHotKeys()

        // Skip registration entirely while the user is recording in
        // Settings — the in-progress key combination must not fire as
        // a hotkey, and the Carbon-level swallow would also prevent
        // the recorder's NSEvent local monitor from observing it.
        guard !isRecordingHotKey else { return }

        registerHotKey(hotKeySettings.windowCaptureHotkey, match: .windowCapture)
        registerHotKey(hotKeySettings.fullScreenHotkey, match: .fullScreen)
    }

    private func registerHotKey(_ hotkey: HotKey, match: Match) {
        guard !hotkey.isUnset else { return }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: match.carbonId)
        let modifiers = Self.carbonModifiers(from: hotkey.modifierFlags)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[match] = ref
        } else {
            // Most common failure: the same key+modifier is already
            // registered system-wide by another app. Carbon does not
            // allow conflicting registrations. Logged for triage; UX
            // surface is the absence of any visible action when the
            // user presses the hotkey.
            NSLog("[HotKeyManager] RegisterEventHotKey failed (status=\(status)) for match=\(match)")
        }
    }

    private func unregisterAllHotKeys() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    fileprivate func dispatchHotKeyId(_ id: UInt32) {
        guard !isRecordingHotKey else { return }
        guard let match = Match(carbonId: id) else { return }
        onHotKey?(match)
    }
}
