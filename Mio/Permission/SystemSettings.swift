//
//  SystemSettings.swift
//  Mio
//
//  Module-12 System Settings opener (M08-04 recovery target + Login Item panel).
//  The single place that knows the Screen Recording privacy deep-link string — no
//  View, Onboarding or 08 feedback code constructs a settings URL, and it is the
//  single owner of every System Settings navigation. Returns a typed result:
//  `NSWorkspace.open` false becomes `.openRejected`, never a silent second-path
//  fallback. `SystemSettingsDestination` is defined in `PermissionManager.swift`.
//

import AppKit
import ServiceManagement

/// 打开系统设置面板失败。Screen Recording opener 与 Login Item 共用。
nonisolated enum SystemSettingsOpenFailure: Error, Sendable, Equatable {
    case openRejected
}

@MainActor
final class SystemSettingsOpener {
    /// Screen Recording privacy pane deep link. Kept here and nowhere else.
    private static let screenRecordingURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )

    func open(_ destination: SystemSettingsDestination) -> Result<Void, SystemSettingsOpenFailure> {
        switch destination {
        case .screenRecording:
            guard let url = Self.screenRecordingURL else { return .failure(.openRejected) }
            return NSWorkspace.shared.open(url) ? .success(()) : .failure(.openRejected)
        case .loginItems:
            SMAppService.openSystemSettingsLoginItems()
            return .success(())
        }
    }
}
