//
//  PastScreenApp.swift
//  PastScreen
//
//  Created by Eric COLOGNI on 03/11/2025.
//

import SwiftUI
import AppKit
import UserNotifications
import Combine
#if canImport(TipKit)
import TipKit
#endif

// Notification names
extension Notification.Name {
    static let screenshotCaptured = Notification.Name("screenshotCaptured")
    static let showInDockChanged = Notification.Name("showInDockChanged")
    static let hotKeyPressed = Notification.Name("hotKeyPressed")
    static let advancedHotKeyPressed = Notification.Name("advancedHotKeyPressed")
}

@main
struct PastScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("PastScreen", systemImage: "camera.viewfinder") {
            MenuBarContentView(app: appDelegate)
        }

        // Pas de fenêtre principale ; les préférences s'ouvrent via le menu
        Settings {
            EmptyView()
        }
    }
}

enum CaptureTrigger: String {
    case menuBar
    case hotkey
    case appIntent
    case automation
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    var screenshotService: ScreenshotService?
    var preferencesWindow: NSWindow?
    var preferencesWindowDelegate: PreferencesWindowDelegate?  // Strong reference
    private var hasPromptedAccessibility = false
    private var hasPromptedScreenRecording = false

    // Services
    var permissionManager = PermissionManager.shared

    var settings = AppSettings.shared
    private let hotKeyManager = HotKeyManager.shared

    // Track last screenshot for "Reveal in Finder" menu item
    @Published var lastScreenshotPath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("🎯 [APP] ====== APPLICATION DID FINISH LAUNCHING ======")
        // Vérifier qu'une seule instance tourne
        if let bundleID = Bundle.main.bundleIdentifier {
            let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if runningInstances.count > 1 {
                NSLog("⚠️ [APP] Une autre instance de PastScreen est déjà en cours d'exécution (\(runningInstances.count))")
                NSLog("💡 [APP] PastScreen est limité à une seule instance - arrêt de cette nouvelle instance")
                NSApp.terminate(nil)
                return
            }
        }

        // Setup notification center delegate
        UNUserNotificationCenter.current().delegate = self

#if canImport(TipKit)
        if #available(macOS 14.0, *) {
            try? Tips.configure()
        }
#endif
        ScreenshotIntentBridge.shared.appDelegate = self

        // IMPORTANT: Don't check permissions at startup to avoid system pop-ups
        // Permissions will be requested through the onboarding flow
        // permissionManager.checkAllPermissions()

        // Don't request notification permission automatically
        // permissionManager.requestPermission(.notifications) { granted in
        //     if granted {
        //         print("✅ [APP] Notifications authorized")
        //     } else {
        //         print("⚠️ [APP] Notifications not authorized - DynamicIslandManager will provide feedback")
        //     }
        // }

        // Initialize services
        screenshotService = ScreenshotService()

        // NOTE: Permissions are now requested via Onboarding only
        // No auto-prompting at launch to avoid popup chaos

        #if DEBUG
        testNotification()
        #endif

        // Start monitoring for the global hotkey. The manager will handle settings changes internally.
        hotKeyManager.startMonitoring()

        // Observe when the hotkey is pressed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotKeyPressed),
            name: .hotKeyPressed,
            object: nil
        )

        // Check permission status (read-only, no popups)
        permissionManager.checkAllPermissions()

        // Observer les captures d'écran réussies pour mettre à jour lastScreenshotPath
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenshotCaptured),
            name: .screenshotCaptured,
            object: nil
        )

        // Observer les changements du mode Dock
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowInDockChanged),
            name: .showInDockChanged,
            object: nil
        )
        
        // Observer for advanced hotkey
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAdvancedHotKeyPressed),
            name: .advancedHotKeyPressed,
            object: nil
        )

        // Configurer le mode initial (Dock ou menu bar seulement)
        updateActivationPolicy()

        // Show onboarding if first launch
        NSLog("🚀 [APP] About to show onboarding...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard self != nil else { return }
            NSLog("🚀 [APP] Calling OnboardingManager.showIfNeeded()")
            OnboardingManager.shared.showIfNeeded()
        }
    }

    @objc func handleScreenshotCaptured(_ notification: Notification) {
        if let path = notification.userInfo?["filePath"] as? String {
            DispatchQueue.main.async { [weak self] in
                self?.lastScreenshotPath = path
            }
        }
    }

    @objc func takeScreenshot() {
        requestScreenRecordingIfNeeded { [weak self] in
            self?.performAreaCapture(source: .menuBar)
        }
    }

    @objc func captureFullScreen() {
        requestScreenRecordingIfNeeded { [weak self] in
            self?.performFullScreenCapture(source: .menuBar)
        }
    }

    @objc func handleHotKeyPressed() {
        requestScreenRecordingIfNeeded { [weak self] in
            self?.performAreaCapture(source: .hotkey)
        }
    }
    
    @objc func handleAdvancedHotKeyPressed() {
        requestScreenRecordingIfNeeded { [weak self] in
            self?.performAdvancedAreaCapture(source: .hotkey)
        }
    }
    
    @objc func captureAdvanced() {
        requestScreenRecordingIfNeeded { [weak self] in
            self?.performAdvancedAreaCapture(source: .menuBar)
        }
    }

    @objc func revealLastScreenshot() {
        guard let path = lastScreenshotPath else { return }

        // Verify file still exists
        guard FileManager.default.fileExists(atPath: path) else {
            // Reset lastScreenshotPath since file doesn't exist
            lastScreenshotPath = nil
            // Show alert
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("error.file_not_found.title", comment: "")
            alert.informativeText = NSLocalizedString("error.file_not_found.message", comment: "")
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func copyFromHistory(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let image = NSImage(contentsOfFile: path) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setString(path, forType: .string)

        if AppSettings.shared.playSoundOnCapture {
            NSSound(named: "Pop")?.play()
        }

        DynamicIslandManager.shared.show(message: "已复制", duration: 1.5)
    }

    @objc func copyFromHistory(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        copyFromHistory(path: path)
    }

    @objc func clearHistory() {
        AppSettings.shared.clearHistory()
    }

    @objc func changeDestinationFolder() {
        // Ensure window is frontmost for the panel
        NSApp.activate(ignoringOtherApps: true)

        if let newPath = AppSettings.shared.selectFolder() {
            AppSettings.shared.saveFolderPath = newPath
            // Also ensure saving is enabled if user explicitly picks a folder
            AppSettings.shared.saveToFile = true
        }
    }

    @objc func openPreferences() {
        // Si la fenêtre existe déjà, la mettre au premier plan
        if let window = preferencesWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Créer la fenêtre de préférences
        let settingsView = SettingsView()
            .environmentObject(AppSettings.shared)

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = NSLocalizedString("window.preferences", comment: "")
        window.contentViewController = hostingController
        window.center()
        window.setFrameAutosaveName("PreferencesWindow")
        window.isReleasedWhenClosed = false

        // Gérer la fermeture de la fenêtre
        let delegate = PreferencesWindowDelegate { [weak self] in
            self?.preferencesWindow = nil
            self?.preferencesWindowDelegate = nil
        }
        self.preferencesWindowDelegate = delegate
        window.delegate = delegate

        self.preferencesWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func quit() {
        // Fermer toutes les fenêtres ouvertes
        preferencesWindow?.close()
        preferencesWindow = nil

        // Cleanup full screen service if needed

        // Terminer l'application (le raccourci reste actif)
        NSApplication.shared.terminate(nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 12.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.banner])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let filePath = response.notification.request.content.userInfo["filePath"] as? String {
            NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
        }

        // Fix: Force activation policy back to accessory if Dock icon shouldn't be shown
        // Clicking a notification might activate the app, making the Dock icon appear.
        if !AppSettings.shared.showInDock {
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        completionHandler()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // HotKeyManager cleans itself up via deinit, so we don't need to call stopMonitoring.
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

#if DEBUG
    func testNotification() {
        let content = UNMutableNotificationContent()
        content.title = "PastScreen-CN - 测试"
        content.body = "应用已启动"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
#endif

    // REMOVED: Auto-permission request functions
    // Permissions are now ONLY requested via Onboarding
    // This prevents popup chaos on first launch

    private func requestAllPermissions() {
        // Check current status of all permissions
        permissionManager.checkAllPermissions()

        // Request Screen Recording permission
        permissionManager.requestPermission(.screenRecording) { _ in }

        // Request Accessibility permission (for global hotkeys)
        permissionManager.requestPermission(.accessibility) { _ in }

        // Check if any permissions are missing after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            let missing = self.permissionManager.getMissingPermissions()
            if !missing.isEmpty {
                // Only show alert if Screen Recording is missing (critical)
                if missing.contains(.screenRecording) {
                    self.permissionManager.showPermissionAlert(for: missing)
                }
            }
        }
    }

    private func requestScreenRecordingIfNeeded(onGranted: @escaping () -> Void) {
        permissionManager.checkScreenRecordingPermission()
        if permissionManager.screenRecordingStatus == .authorized {
            onGranted()
            return
        }

        permissionManager.requestPermission(.screenRecording) { granted in
            DispatchQueue.main.async {
                if granted {
                    onGranted()
                } else {
                    self.permissionManager.showPermissionAlert(for: [.screenRecording])
                }
            }
        }
    }

    func performAreaCapture(source: CaptureTrigger = .menuBar) {
        guard let screenshotService = screenshotService else { return }
        screenshotService.capturePreviousApp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak screenshotService] in
            screenshotService?.captureScreenshot()
        }
    }

    func performAdvancedAreaCapture(source: CaptureTrigger = .menuBar) {
        guard let screenshotService = screenshotService else { return }
        screenshotService.capturePreviousApp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak screenshotService] in
            screenshotService?.captureAdvancedScreenshot()
        }
    }

    func performFullScreenCapture(source: CaptureTrigger = .menuBar) {
        guard let screenshotService = screenshotService else { return }
        screenshotService.capturePreviousApp()
        screenshotService.captureFullScreen()
    }

    // MARK: - Raccourci clavier global

    // All global hotkey logic has been refactored into the HotKeyManager class
    // to improve separation of concerns. The manager is initialized at launch
    // and communicates with AppDelegate via NotificationCenter.

    // MARK: - Dock Icon Management

    @objc func handleShowInDockChanged() {
        updateActivationPolicy()
    }

    func updateActivationPolicy() {
        let showInDock = settings.showInDock

        if showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Preferences Window Delegate

class PreferencesWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
