//
//  PermissionManager.swift
//  Mio
//
//  Tracks Screen Recording / Accessibility permission status and
//  exposes async helpers to request them.
//

import Foundation
import AppKit
import Combine

enum PermissionType: CaseIterable, Sendable {
    case screenRecording
    case accessibility

    /// Used inside `showPermissionAlert` informativeText, displayed to
    /// the user. Not a developer-facing log.
    var icon: String {
        switch self {
        case .screenRecording: return "📱"
        case .accessibility: return "♿️"
        }
    }

    var localizedName: String {
        switch self {
        case .screenRecording:
            return NSLocalizedString("permission.type.screen_recording", value: "屏幕录制", comment: "")
        case .accessibility:
            return NSLocalizedString("permission.type.accessibility", value: "辅助功能", comment: "")
        }
    }
}

enum PermissionStatus: Sendable {
    case authorized
    case denied
    case notDetermined
    case restricted
}

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published var screenRecordingStatus: PermissionStatus = .notDetermined
    @Published var accessibilityStatus: PermissionStatus = .notDetermined

    private init() {}

    // MARK: - Status checking

    func checkAllPermissions() {
        checkScreenRecordingPermission()
        checkAccessibilityPermission()
    }

    func checkScreenRecordingPermission() {
        screenRecordingStatus = CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    func checkAccessibilityPermission() {
        accessibilityStatus = AXIsProcessTrusted() ? .authorized : .denied
    }

    // MARK: - Requests

    /// Prompts the user (via the system dialog) for the requested
    /// permission and returns whether it was granted. Re-checks status
    /// after a short delay so the @Published properties reflect the
    /// post-prompt state for any UI bound to them.
    func requestPermission(_ type: PermissionType) async -> Bool {
        switch type {
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() {
                checkScreenRecordingPermission()
                return true
            }
            CGRequestScreenCaptureAccess()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            checkScreenRecordingPermission()
            return screenRecordingStatus == .authorized

        case .accessibility:
            if AXIsProcessTrusted() {
                checkAccessibilityPermission()
                return true
            }
            // Use the string literal instead of `kAXTrustedCheckOptionPrompt`
            // to avoid the Swift 6 concurrency-safety warning on the
            // global CF constant.
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            checkAccessibilityPermission()
            return accessibilityStatus == .authorized
        }
    }

    // MARK: - User feedback

    func showPermissionAlert(for permissions: [PermissionType]) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("error.permission_denied", value: "需要权限", comment: "")

        let header = NSLocalizedString("permission.request.header", value: "Mio 需要以下权限才能正常工作：", comment: "")
        let footer = NSLocalizedString("permission.request.footer", value: "请在“系统设置 → 隐私与安全性”中开启。", comment: "")
        let permissionsList = permissions.map { "\($0.icon) \($0.localizedName)" }.joined(separator: "\n")

        alert.informativeText = "\(header)\n\n\(permissionsList)\n\n\(footer)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("error.open_system_prefs", value: "打开系统设置", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("error.later", value: "稍后", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            openSystemPreferences()
        }
    }

    func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }
}
