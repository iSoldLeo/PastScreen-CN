//
//  PermissionManager.swift
//  PastScreen
//
//  Comprehensive permission management with retry logic and diagnostics
//

import Foundation
import AppKit
import UserNotifications
import Combine

enum PermissionType: CaseIterable, Sendable {
    case screenRecording
    case accessibility
    case notifications

    var icon: String {
        switch self {
        case .screenRecording: return "📱"
        case .accessibility: return "♿️"
        case .notifications: return "🔔"
        }
    }

    var localizedName: String {
        switch self {
        case .screenRecording:
            return NSLocalizedString("permission.type.screen_recording", value: "屏幕录制", comment: "")
        case .accessibility:
            return NSLocalizedString("permission.type.accessibility", value: "辅助功能", comment: "")
        case .notifications:
            return NSLocalizedString("permission.type.notifications", value: "通知", comment: "")
        }
    }
}

enum PermissionStatus: Sendable {
    case authorized
    case denied
    case notDetermined
    case restricted

    var description: String {
        switch self {
        case .authorized: return "✅ Authorized"
        case .denied: return "❌ Denied"
        case .notDetermined: return "⏳ Not Determined"
        case .restricted: return "🚫 Restricted"
        }
    }
}

@MainActor
class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published var screenRecordingStatus: PermissionStatus = .notDetermined
    @Published var accessibilityStatus: PermissionStatus = .notDetermined
    @Published var notificationStatus: PermissionStatus = .notDetermined

    private var retryCount: [PermissionType: Int] = [:]
    private let maxRetries = 3

    // MARK: - Permission Status Checking

    func checkAllPermissions() {
        checkScreenRecordingPermission()
        checkAccessibilityPermission()
        checkNotificationPermission()
    }

    func checkScreenRecordingPermission() {
        if #available(macOS 10.15, *) {
            let hasAccess = CGPreflightScreenCaptureAccess()
            screenRecordingStatus = hasAccess ? .authorized : .denied
        }
    }

    func checkAccessibilityPermission() {
        let hasAccess = AXIsProcessTrusted()
        accessibilityStatus = hasAccess ? .authorized : .denied
    }

    func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                switch status {
                case .authorized, .provisional, .ephemeral:
                    self.notificationStatus = .authorized
                case .denied:
                    self.notificationStatus = .denied
                case .notDetermined:
                    self.notificationStatus = .notDetermined
                @unknown default:
                    self.notificationStatus = .restricted
                }
            }
        }
    }

    // MARK: - Permission Requests with Retry

    func requestPermission(_ type: PermissionType, completion: @escaping @Sendable (Bool) -> Void) {
        let currentRetry = retryCount[type] ?? 0

        if currentRetry >= maxRetries {
            showMaxRetriesAlert(for: type)
            completion(false)
            return
        }

        retryCount[type] = currentRetry + 1

        switch type {
        case .screenRecording:
            requestScreenRecording(completion: completion)
        case .accessibility:
            requestAccessibility(completion: completion)
        case .notifications:
            requestNotifications(completion: completion)
        }
    }

    private func requestScreenRecording(completion: @escaping @Sendable (Bool) -> Void) {
        if #available(macOS 10.15, *) {
            let wasAuthorized = CGPreflightScreenCaptureAccess()
            if !wasAuthorized {
                CGRequestScreenCaptureAccess()

                // Check again after a delay
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self.checkScreenRecordingPermission()
                    completion(self.screenRecordingStatus == .authorized)
                }
            } else {
                completion(true)
            }
        }
    }

    private func requestAccessibility(completion: @escaping @Sendable (Bool) -> Void) {
        let wasAuthorized = AXIsProcessTrusted()
        if !wasAuthorized {
            // Use string literal instead of kAXTrustedCheckOptionPrompt to avoid
            // Swift 6 concurrency-safety warning on the global CF constant.
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            let _ = AXIsProcessTrustedWithOptions(options)

            // Check again after a delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.checkAccessibilityPermission()
                completion(self.accessibilityStatus == .authorized)
            }
        } else {
            completion(true)
        }
    }

    private func requestNotifications(completion: @escaping @Sendable (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                self.checkNotificationPermission()
                completion(granted)
            }
        }
    }

    // MARK: - User Feedback

    func allPermissionsGranted() -> Bool {
        return screenRecordingStatus == .authorized &&
               accessibilityStatus == .authorized &&
               notificationStatus == .authorized
    }

    func getMissingPermissions() -> [PermissionType] {
        var missing: [PermissionType] = []

        if screenRecordingStatus != .authorized {
            missing.append(.screenRecording)
        }
        if accessibilityStatus != .authorized {
            missing.append(.accessibility)
        }
        if notificationStatus != .authorized {
            missing.append(.notifications)
        }

        return missing
    }

    func showPermissionAlert(for permissions: [PermissionType]) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("error.permission_denied", value: "需要权限", comment: "")

        let header = NSLocalizedString("permission.request.header", value: "PastScreen-CN 需要以下权限才能正常工作：", comment: "")
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

    private func showMaxRetriesAlert(for type: PermissionType) {
        let alert = NSAlert()
        alert.messageText = "\(type.icon) \(type.localizedName) " + NSLocalizedString("error.permission_denied", value: "需要权限", comment: "")

        let message = NSLocalizedString("permission.max_retries.message", value: "PastScreen-CN 已达到权限请求次数上限。\n\n请手动开启", comment: "")

        alert.informativeText = """
        \(message) \(type.localizedName):
        系统设置 → 隐私与安全性 → \(type.localizedName)
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("error.open_system_prefs", value: "打开系统设置", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("common.ok", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            openSystemPreferences()
        }
    }

    func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Reset

    func resetRetryCounters() {
        retryCount.removeAll()
    }

    // MARK: - Convenience Methods

    func requestAccessibilityPermission(completion: @escaping @Sendable (Bool) -> Void) {
        requestPermission(.accessibility, completion: completion)
    }

    func requestScreenRecordingPermission(completion: @escaping @Sendable (Bool) -> Void) {
        requestPermission(.screenRecording, completion: completion)
    }

    var hasAllPermissions: Bool {
        return screenRecordingStatus == .authorized && accessibilityStatus == .authorized
    }
}
