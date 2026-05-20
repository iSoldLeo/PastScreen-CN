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

enum PermissionType: String, CaseIterable {
    case screenRecording = "Screen Recording"
    case accessibility = "Accessibility"
    case notifications = "Notifications"

    var icon: String {
        switch self {
        case .screenRecording: return "📱"
        case .accessibility: return "♿️"
        case .notifications: return "🔔"
        }
    }
}

enum PermissionStatus {
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
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
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

    func requestPermission(_ type: PermissionType, completion: @escaping (Bool) -> Void) {
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

    private func requestScreenRecording(completion: @escaping (Bool) -> Void) {
        if #available(macOS 10.15, *) {
            let wasAuthorized = CGPreflightScreenCaptureAccess()
            if !wasAuthorized {
                CGRequestScreenCaptureAccess()

                // Check again after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.checkScreenRecordingPermission()
                    completion(self.screenRecordingStatus == .authorized)
                }
            } else {
                completion(true)
            }
        }
    }

    private func requestAccessibility(completion: @escaping (Bool) -> Void) {
        let wasAuthorized = AXIsProcessTrusted()
        if !wasAuthorized {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            let _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

            // Check again after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.checkAccessibilityPermission()
                completion(self.accessibilityStatus == .authorized)
            }
        } else {
            completion(true)
        }
    }

    private func requestNotifications(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
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
        alert.messageText = NSLocalizedString("error.permission_denied", value: "Permissions Required", comment: "")

        let header = NSLocalizedString("permission.request.header", value: "PastScreen needs the following permissions to work properly:", comment: "")
        let footer = NSLocalizedString("permission.request.footer", value: "Please enable them in System Preferences > Privacy & Security.", comment: "")
        let permissionsList = permissions.map { "\($0.icon) \($0.rawValue)" }.joined(separator: "\n")

        alert.informativeText = "\(header)\n\n\(permissionsList)\n\n\(footer)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("error.open_system_prefs", value: "Open System Preferences", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("error.later", value: "Later", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            openSystemPreferences()
        }
    }

    private func showMaxRetriesAlert(for type: PermissionType) {
        let alert = NSAlert()
        alert.messageText = "\(type.icon) \(type.rawValue) " + NSLocalizedString("error.permission_denied", value: "Permission Required", comment: "")

        let message = NSLocalizedString("permission.max_retries.message", value: "PastScreen has reached the maximum number of permission requests.\n\nPlease manually enable", comment: "")

        alert.informativeText = """
        \(message) \(type.rawValue):
        System Preferences > Privacy & Security > \(type.rawValue)
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("error.open_system_prefs", value: "Open System Preferences", comment: ""))
        alert.addButton(withTitle: "OK")

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

    func requestAccessibilityPermission(completion: @escaping (Bool) -> Void) {
        requestPermission(.accessibility, completion: completion)
    }

    func requestScreenRecordingPermission(completion: @escaping (Bool) -> Void) {
        requestPermission(.screenRecording, completion: completion)
    }

    var hasAllPermissions: Bool {
        return screenRecordingStatus == .authorized && accessibilityStatus == .authorized
    }
}
