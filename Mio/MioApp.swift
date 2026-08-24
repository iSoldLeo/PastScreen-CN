//
//  MioApp.swift
//  Mio
//
//  App entry point and AppDelegate. The delegate is only the AppKit
//  lifecycle bridge; AppServices owns the process graph and command router.
//

import SwiftUI
import AppKit

@main
struct MioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Mio", systemImage: "camera.viewfinder") {
            MenuBarContentView(
                shortcutService: appDelegate.services.globalShortcutService,
                shortcutFormatter: appDelegate.services.shortcutFormatter,
                submitCapture: { [router = appDelegate.services.captureCommandRouter] command, source in
                    router.submit(command, source: source)
                },
                quit: { [weak appDelegate] in
                    appDelegate?.quit()
                }
            )
        }

        // No main window — preferences open from the menu bar.
        Settings {
            SettingsView(
                shortcutStore: appDelegate.services.shortcutStore,
                shortcutService: appDelegate.services.globalShortcutService,
                shortcutFormatter: appDelegate.services.shortcutFormatter,
                presentOnboarding: { [weak services = appDelegate.services] in
                    services?.showOnboarding()
                }
            )
                .environmentObject(appDelegate.services.launchAtLoginController)
                .environmentObject(appDelegate.services.captureSettings)
                .environmentObject(appDelegate.services.saveFolderAccess)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let runningInstanceCount = duplicateInstanceCount() {
            services.stop(reason: .duplicateInstance(runningInstanceCount: runningInstanceCount))
            NSApp.terminate(nil)
            return
        }

        // Menu bar app: no Dock icon, accessory activation policy.
        NSApp.setActivationPolicy(.accessory)
        services.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        services.didBecomeActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.stop(reason: .applicationTermination)
    }

    func quit() {
        services.stop(reason: .userQuit)
        NSApplication.shared.terminate(nil)
    }

    // The menu bar app survives all window closures.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func duplicateInstanceCount() -> Int? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let count = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count
        return count > 1 ? count : nil
    }
}
