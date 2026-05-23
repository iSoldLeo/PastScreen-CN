//
//  MioApp.swift
//  Mio
//
//  App entry point and AppDelegate. Bridges AppKit lifecycle events to
//  the SwiftUI MenuBarExtra/Settings scenes and the capture pipeline.
//

import SwiftUI
import AppKit

@main
struct MioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Mio", systemImage: "camera.viewfinder") {
            MenuBarContentView(app: appDelegate)
        }

        // No main window — preferences open from the menu bar.
        Settings {
            SettingsView()
                .environmentObject(AppSettings.shared.appearance)
                .environmentObject(AppSettings.shared.hotkey)
                .environmentObject(AppSettings.shared.capture)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let coordinator = CaptureCoordinator()

    private let permissionManager = PermissionManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAlreadyRunningElsewhere() {
            NSApp.terminate(nil)
            return
        }

        // Permissions are checked read-only at launch. User-facing
        // prompts belong to the (yet-to-be-implemented) onboarding
        // flow, not here.
        permissionManager.checkAllPermissions()

        HotKeyManager.shared.start { [weak self] in
            self?.handleHotKeyPressed()
        }

        // Menu bar app: no Dock icon, accessory activation policy.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Hotkey

    private func handleHotKeyPressed() {
        Task { [weak self] in
            guard let self else { return }
            if await self.ensureScreenRecordingGranted() {
                self.coordinator.startAreaCapture()
            }
        }
    }

    // MARK: - Menu actions

    @objc func takeScreenshot() {
        Task { [weak self] in
            guard let self else { return }
            if await self.ensureScreenRecordingGranted() {
                self.coordinator.startAreaCapture()
            }
        }
    }

    @objc func captureFullScreen() {
        Task { [weak self] in
            guard let self else { return }
            if await self.ensureScreenRecordingGranted() {
                self.coordinator.startFullScreenCapture()
            }
        }
    }

    @objc func changeDestinationFolder() {
        // Bring Mio to front so NSOpenPanel attaches as expected.
        NSApp.activate(ignoringOtherApps: true)

        if let newPath = AppSettings.shared.capture.selectFolder() {
            AppSettings.shared.capture.saveFolderPath = newPath
        }
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    // The menu bar app survives all window closures.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Private

    private func isAlreadyRunningElsewhere() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1
    }

    /// Returns `true` once Screen Recording is granted; otherwise
    /// presents the permission alert and returns `false` so the caller
    /// skips the capture flow.
    private func ensureScreenRecordingGranted() async -> Bool {
        permissionManager.checkScreenRecordingPermission()
        if permissionManager.screenRecordingStatus == .authorized {
            return true
        }
        let granted = await permissionManager.requestPermission(.screenRecording)
        if !granted {
            permissionManager.showPermissionAlert(for: [.screenRecording])
        }
        return granted
    }
}
