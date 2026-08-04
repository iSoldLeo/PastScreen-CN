//
//  MioApp.swift
//  Mio
//
//  App entry point and AppDelegate. Bridges AppKit lifecycle events to
//  the SwiftUI MenuBarExtra/Settings scenes and the capture pipeline.
//

import SwiftUI
import AppKit
import Combine  // ObservableObject conformance synthesis (Xcode 26 no longer relies on SwiftUI re-export)

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
                .environmentObject(AppSettings.shared.general)
                .environmentObject(AppSettings.shared.hotkey)
                .environmentObject(AppSettings.shared.capture)
        }

        // Onboarding 窗口：使用 macOS 26 原生 SwiftUI Window chrome。
        //
        // 不再走 .windowStyle(.plain)：plain 会创建无系统 chrome 的窗口，
        // 需要自绘圆角/阴影/拖拽/焦点，反而绕开 Tahoe 原生窗口外观。
        // 这里保留默认窗口样式，只移除标题文字和 toolbar 背板，让内容延展
        // 到顶部；圆角、阴影、focus、拖拽与 Liquid Glass 背景全部交给系统。
        Window("Mio", id: "onboarding") {
            OnboardingView()
                .environmentObject(AppSettings.shared.hotkey)
                .environmentObject(AppSettings.shared.capture)
                // Tahoe 的大窗口圆角由真实 toolbar chrome 触发；仅移除标题
                // 会退回 titlebar-only 小圆角。放一个轻量帮助按钮作为
                // 原生 toolbar item，让系统按 toolbar 窗口计算外轮廓。
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            // 预留帮助入口：当前 onboarding 先只用它触发 Tahoe
                            // 原生 toolbar 大圆角，后续再接具体帮助动作。
                        } label: {
                            Image(systemName: "questionmark")
                        }
                        // Same key the AppKit onboarding toolbar uses
                        // (OnboardingPresenter), so there is one "Help" string.
                        .help("onboarding.help")
                        .accessibilityLabel("onboarding.help")
                    }
                }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.center, width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        }
        .restorationBehavior(.disabled)
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

        // PRODUCT v5 §5.1: SCK 启动预热——派一次极小尺寸 dummy 抓图，把
        // ScreenCaptureKit XPC 链路、IOSurface 资源池、权限校验缓存全部
        // 初始化到位，消除首次按键的 ~300ms 进程级冷启动。失败静默忽略。
        Task.detached(priority: .utility) {
            await DisplayCaptureService().prewarm()
        }

        HotKeyManager.shared.start { [weak self] match in
            switch match {
            case .windowCapture:
                self?.handleWindowHotKey()
            case .fullScreen:
                self?.handleFullScreenHotKey()
            case .advancedWindowCapture:
                self?.handleAdvancedWindowHotKey()
            }
        }

        // Menu bar app: no Dock icon, accessory activation policy.
        NSApp.setActivationPolicy(.accessory)

        if OnboardingPresenter.shouldShowOnLaunch {
            OnboardingPresenter.shared.show()
        }
    }

    // MARK: - Hotkey

    private func handleWindowHotKey() {
        Task { [weak self] in
            guard let self else { return }
            if await self.ensureScreenRecordingGranted() {
                self.coordinator.startAreaCapture()
            }
        }
    }

    private func handleFullScreenHotKey() {
        Task { [weak self] in
            guard let self else { return }
            if await self.ensureScreenRecordingGranted() {
                self.coordinator.startFullScreenCapture()
            }
        }
    }

    private func handleAdvancedWindowHotKey() {
        Task { [weak self] in
            guard let self else { return }
            if await self.ensureScreenRecordingGranted() {
                self.coordinator.startAdvancedAreaCapture()
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

    @objc func takeAdvancedScreenshot() {
        Task { [weak self] in
            guard let self else { return }
            if await self.ensureScreenRecordingGranted() {
                self.coordinator.startAdvancedAreaCapture()
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

    /// Returns `true` once Screen Recording is granted; otherwise returns
    /// `false` so the caller skips the capture flow. The user-facing
    /// guidance (system dialog on first request, onboarding redirect on
    /// repeat denial) lives outside this function.
    private func ensureScreenRecordingGranted() async -> Bool {
        permissionManager.checkScreenRecordingPermission()
        if permissionManager.screenRecordingStatus == .authorized {
            return true
        }
        return await permissionManager.requestPermission(.screenRecording)
    }
}
