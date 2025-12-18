//
//  HotKeyManager.swift
//  PastScreen
//
//  Created by Eric COLOGNI on 2025-11-20.
//
//  Manages the global hotkey for capturing screenshots.
//

import Foundation
import AppKit
import Combine

class HotKeyManager {

    static let shared = HotKeyManager()

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private let settings = AppSettings.shared
    private let permissionManager = PermissionManager.shared
    private var settingsObserver: AnyCancellable?
    private var advancedHotkeyObserver: AnyCancellable?
    private var permissionObserver: AnyCancellable?
    private var isRecordingHotKey = false

    private init() {
        // Observe changes to the hotkey enabled setting.
        // This allows enabling/disabling the hotkey from the Settings window
        // without needing to restart the app.
        settingsObserver = settings.$globalHotkeyEnabled.sink { [weak self] enabled in
            DispatchQueue.main.async {
                if enabled {
                    self?.startMonitoring()
                } else {
                    self?.stopMonitoring()
                }
            }
        }
        
        // Also observe changes to the advanced hotkey enabled setting
        advancedHotkeyObserver = settings.$advancedHotkeyEnabled.sink { [weak self] _ in
            DispatchQueue.main.async {
                if self?.settings.globalHotkeyEnabled == true {
                    self?.startMonitoring()
                }
            }
        }

        // Restart monitoring automatically once Accessibility permission is granted
        permissionObserver = permissionManager.$accessibilityStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                if status == .authorized {
                    self.startMonitoring()
                } else {
                    self.stopMonitoring()
                }
            }
    }

    deinit {
        stopMonitoring()
        settingsObserver?.cancel()
        advancedHotkeyObserver?.cancel()
        permissionObserver?.cancel()
    }

    /// Starts listening for the global hotkey if it's enabled in settings.
    func startMonitoring() {
        // Ensure we don't create multiple monitors by stopping any existing ones.
        stopMonitoring()

        guard settings.globalHotkeyEnabled else {
            return
        }

        // The hotkey requires Accessibility permissions. We check for them here but
        // do not prompt the user. The onboarding flow is responsible for requesting permissions.
        guard AXIsProcessTrusted() else {
            return
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = self.handleHotKeyEvent(event)
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.handleHotKeyEvent(event) {
                return nil
            }
            return event
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
    private func handleHotKeyEvent(_ event: NSEvent) -> Bool {
        guard !isRecordingHotKey else { return false }

        // Check for regular screenshot hotkey
        let hotkey = settings.globalHotkey
        let requiredModifiers = hotkey.modifierFlags
        let eventModifiers = HotKey.normalizedModifiers(event.modifierFlags)

        let matchesModifiers = eventModifiers == requiredModifiers
        let matchesKeyCode = event.keyCode == hotkey.keyCode
        let matchesCharacters = {
            guard let expected = hotkey.characters?.lowercased(),
                  let actual = event.charactersIgnoringModifiers?.lowercased() else {
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
        
        // Check for advanced screenshot hotkey
        if settings.advancedHotkeyEnabled {
            let advancedHotkey = settings.advancedHotkey
            let advancedModifiers = advancedHotkey.modifierFlags
            
            let matchesAdvancedModifiers = eventModifiers == advancedModifiers
            let matchesAdvancedKeyCode = event.keyCode == advancedHotkey.keyCode
            let matchesAdvancedCharacters = {
                guard let expected = advancedHotkey.characters?.lowercased(),
                      let actual = event.charactersIgnoringModifiers?.lowercased() else {
                    return false
                }
                return expected == actual
            }()
            
            if matchesAdvancedModifiers && (matchesAdvancedKeyCode || matchesAdvancedCharacters) {
                // Post notification for advanced screenshot
                NotificationCenter.default.post(name: .advancedHotKeyPressed, object: nil)
                return true
            }
        }

        return false
    }
}
