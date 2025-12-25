//
//  TutorialView.swift
//  PastScreen
//
//  In-app user guide window (how to use PastScreen-CN)
//

import SwiftUI
import AppKit

final class TutorialWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TutorialManager: NSObject, NSWindowDelegate {
    static let shared = TutorialManager()

    private var window: TutorialWindow?
    private var hostingController: NSHostingController<TutorialContentView>?
    private var captureFlowObserver: Any?

    func show() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if let window = self.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let view = TutorialContentView { [weak self] in
                self?.dismiss()
            }

            let host = NSHostingController(rootView: view)
            self.hostingController = host

            let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
            let width = min(1100, max(900, screenFrame.width * 0.78))
            let height = min(900, max(740, screenFrame.height * 0.82))
            let rect = NSRect(x: 0, y: 0, width: width, height: height)

            let window = TutorialWindow(
                contentRect: rect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )

            window.title = NSLocalizedString("tutorial.window.title", value: "使用指南", comment: "")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 900, height: 720)
            window.setFrameAutosaveName("TutorialWindow")
            window.contentViewController = host
            window.center()
            window.delegate = self
            window.makeKeyAndOrderFront(nil)

            self.window = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let captureFlowObserver {
                NotificationCenter.default.removeObserver(captureFlowObserver)
                self.captureFlowObserver = nil
            }
            self.window?.close()
            self.window = nil
            self.hostingController = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let captureFlowObserver {
            NotificationCenter.default.removeObserver(captureFlowObserver)
            self.captureFlowObserver = nil
        }
        window = nil
        hostingController = nil
    }

    func tryQuickCapture() {
        startCapture(kind: .quick)
    }

    func tryAdvancedCapture() {
        startCapture(kind: .advanced)
    }

    private enum CaptureKind {
        case quick
        case advanced
    }

    private func startCapture(kind: CaptureKind) {
        let manager = PermissionManager.shared
        manager.checkScreenRecordingPermission()

        let begin: () -> Void = { [weak self] in
            guard let self else { return }
            guard let screenshotService = (NSApp.delegate as? AppDelegate)?.screenshotService else { return }

            self.window?.orderOut(nil)

            if self.captureFlowObserver == nil {
                self.captureFlowObserver = NotificationCenter.default.addObserver(
                    forName: .captureFlowEnded,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                screenshotService.capturePreviousApp()
                switch kind {
                case .quick:
                    screenshotService.captureScreenshot(trigger: .menuBar)
                case .advanced:
                    screenshotService.captureAdvancedScreenshot(trigger: .menuBar)
                }
            }
        }

        if manager.screenRecordingStatus == .authorized {
            begin()
            return
        }

        manager.requestPermission(.screenRecording) { granted in
            DispatchQueue.main.async {
                if granted {
                    begin()
                } else {
                    manager.showPermissionAlert(for: [.screenRecording])
                }
            }
        }
    }
}

private struct TutorialContentView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissionManager = PermissionManager.shared
    @Environment(\.openSettings) private var openSettings

    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    introSection
                    permissionsSection
                    shortcutsSection
                    captureTipsSection
                    storageSection
                    troubleshootingSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .background {
            Rectangle().fill(.ultraThinMaterial)
        }
        .onAppear {
            permissionManager.checkAllPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("tutorial.title", value: "PastScreen-CN 使用指南", comment: ""))
                    .font(.title2.weight(.semibold))
                Text(NSLocalizedString("tutorial.subtitle", value: "快速截图，自动进剪贴板。", comment: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openSettings()
            } label: {
                Label(NSLocalizedString("tutorial.open_settings", value: "打开设置", comment: ""), systemImage: "gearshape")
            }
            .buttonStyle(.bordered)

            Button {
                onDismiss()
            } label: {
                Text(NSLocalizedString("tutorial.close", value: "关闭", comment: ""))
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var introSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(NSLocalizedString("tutorial.section.getting_started", value: "立即开始", comment: ""), systemImage: "sparkles")
                    .font(.headline)

                Text(NSLocalizedString("tutorial.getting_started.body", value: "PastScreen-CN 是菜单栏截图工具：选区后会自动复制到剪贴板；也可以按需保存到文件。", comment: ""))
                    .foregroundStyle(.secondary)

                Text(NSLocalizedString("tutorial.getting_started.steps", value: "1. 首次使用先授权「屏幕录制」「辅助功能」。\n2. 按快捷键开始选区截图。\n3. 需要标注就用「高级截图」。\n4. 想落盘就去设置 > 存储选择目录并开启保存。", comment: ""))
                    .font(.callout)
            }
        }
    }

    private var permissionsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(NSLocalizedString("tutorial.section.permissions", value: "权限（必须）", comment: ""), systemImage: "hand.raised.fill")
                    .font(.headline)

                PermissionRow(
                    title: NSLocalizedString("permission.type.screen_recording", value: "屏幕录制", comment: ""),
                    status: permissionManager.screenRecordingStatus,
                    requestTitle: NSLocalizedString("tutorial.permission.request", value: "请求授权", comment: ""),
                    onRequest: {
                        PermissionManager.shared.requestPermission(.screenRecording) { granted in
                            if !granted {
                                openSystemPreferencesPrivacy(pane: "ScreenCapture")
                            }
                        }
                    },
                    onOpenSettings: {
                        openSystemPreferencesPrivacy(pane: "ScreenCapture")
                    }
                )

                PermissionRow(
                    title: NSLocalizedString("permission.type.accessibility", value: "辅助功能", comment: ""),
                    status: permissionManager.accessibilityStatus,
                    requestTitle: NSLocalizedString("tutorial.permission.request", value: "请求授权", comment: ""),
                    onRequest: {
                        PermissionManager.shared.requestPermission(.accessibility) { granted in
                            if !granted {
                                openSystemPreferencesPrivacy(pane: "Accessibility")
                            }
                        }
                    },
                    onOpenSettings: {
                        openSystemPreferencesPrivacy(pane: "Accessibility")
                    }
                )

                Text(NSLocalizedString("tutorial.permissions.footer", value: "路径：系统设置 → 隐私与安全性 → 屏幕录制 / 辅助功能。", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(NSLocalizedString("tutorial.section.shortcuts", value: "快捷键", comment: ""), systemImage: "keyboard")
                    .font(.headline)

                ShortcutRow(
                    title: NSLocalizedString("tutorial.shortcut.quick", value: "选区截图", comment: ""),
                    enabled: settings.globalHotkeyEnabled,
                    hotKey: settings.globalHotkey
                )
                ShortcutRow(
                    title: NSLocalizedString("tutorial.shortcut.advanced", value: "高级截图（标注）", comment: ""),
                    enabled: settings.advancedHotkeyEnabled,
                    hotKey: settings.advancedHotkey
                )
                ShortcutRow(
                    title: NSLocalizedString("tutorial.shortcut.ocr", value: "OCR 截图", comment: ""),
                    enabled: settings.ocrHotkeyEnabled,
                    hotKey: settings.ocrHotkey
                )

                Text(NSLocalizedString("tutorial.shortcuts.footer", value: "可在设置 > 截图中重新录制快捷键。", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var captureTipsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(NSLocalizedString("tutorial.section.capture", value: "怎么截图", comment: ""), systemImage: "camera.fill")
                    .font(.headline)

                Text(NSLocalizedString("tutorial.capture.tips", value: "• 按快捷键后拖拽选择区域；松开即完成。\n• 选区中右键可取消。\n• 完成后会自动复制到剪贴板；菜单栏里也能查看/复制历史。", comment: ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storageSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(NSLocalizedString("tutorial.section.storage", value: "保存到文件（可选）", comment: ""), systemImage: "folder.fill")
                    .font(.headline)

                Text(NSLocalizedString("tutorial.storage.body", value: "默认会复制到剪贴板。若你希望自动保存到文件：在设置 > 存储里开启保存，并选择一个保存目录。", comment: ""))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    StatusPill(
                        title: NSLocalizedString("tutorial.storage.switch", value: "自动保存", comment: ""),
                        isOn: settings.saveToFile
                    )

                    StatusPill(
                        title: NSLocalizedString("tutorial.storage.folder", value: "保存目录", comment: ""),
                        isOn: settings.hasValidSaveFolder
                    )
                }
            }
        }
    }

    private var troubleshootingSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(NSLocalizedString("tutorial.section.troubleshooting", value: "常见问题", comment: ""), systemImage: "wrench.and.screwdriver.fill")
                    .font(.headline)

                Text(NSLocalizedString("tutorial.troubleshooting.body", value: "• 快捷键不生效：检查「辅助功能」是否已允许 PastScreen-CN。\n• 无法截图：检查「屏幕录制」权限；授权后可能需要重启应用。\n• 找不到文件：若未开启保存，截图只在剪贴板中。", comment: ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openSystemPreferencesPrivacy(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let requestTitle: String
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if status != .authorized {
                Button(requestTitle, action: onRequest)
                    .buttonStyle(.bordered)
                Button(NSLocalizedString("tutorial.open_system_settings", value: "打开系统设置", comment: ""), action: onOpenSettings)
                    .buttonStyle(.bordered)
            } else {
                Label(NSLocalizedString("tutorial.permission.granted", value: "已授权", comment: ""), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var statusLabel: String {
        switch status {
        case .authorized:
            return NSLocalizedString("tutorial.permission.status.authorized", value: "已允许", comment: "")
        case .denied:
            return NSLocalizedString("tutorial.permission.status.denied", value: "未允许", comment: "")
        case .notDetermined:
            return NSLocalizedString("tutorial.permission.status.not_determined", value: "未确定", comment: "")
        case .restricted:
            return NSLocalizedString("tutorial.permission.status.restricted", value: "受限制", comment: "")
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let enabled: Bool
    let hotKey: HotKey

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            if enabled {
                Text(hotKey.displayString)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text(NSLocalizedString("tutorial.shortcut.disabled", value: "未启用", comment: ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StatusPill: View {
    let title: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
            Text(isOn ? NSLocalizedString("tutorial.status.on", value: "已开启", comment: "") : NSLocalizedString("tutorial.status.off", value: "未配置", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassContainer(material: .thinMaterial, cornerRadius: 10, borderOpacity: 0.14, shadowOpacity: 0.04)
    }
}
