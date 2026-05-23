//
//  PermissionManager.swift
//  Mio
//
//  Tracks Screen Recording / Accessibility permission status and
//  exposes async helpers to request them.
//
//  No bespoke alert UI: macOS itself shows a system TCC dialog on the
//  first call to `CGRequestScreenCaptureAccess()` (the Info.plist
//  `NSScreenCaptureUsageDescription` string is the user-visible
//  rationale). The "user has previously denied → system stops asking"
//  edge case is delegated to the onboarding flow (see 06 plan).
//

import Foundation
import AppKit
import Combine

enum PermissionType: CaseIterable, Sendable {
    case screenRecording
    case accessibility
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

    /// Prompts the user (via the system TCC dialog) for the requested
    /// permission and returns whether it was granted. Re-checks status
    /// after a short delay so the @Published properties reflect the
    /// post-prompt state for any UI bound to them.
    ///
    /// Note: macOS only shows the system dialog on the *first* call.
    /// If the user has previously denied, this function returns false
    /// silently — the onboarding flow is responsible for guiding the
    /// user to System Settings in that case.
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
}
