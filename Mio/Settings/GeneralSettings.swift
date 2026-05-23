//
//  GeneralSettings.swift
//  Mio
//
//  General settings: launch-at-login. (Was previously named
//  AppearanceSettings; renamed to align with the SwiftUI Settings tab
//  semantics now that all theme-/appearance-related fields have been
//  removed in earlier cleanup batches.)
//  Owns the launchd registration side-effect.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class GeneralSettings: ObservableObject {

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: SettingsKeys.launchAtLogin)
            // Drive the SMAppService registration. The actual launchd
            // round-trip runs on a detached utility-priority task inside
            // `setEnabled`, so this didSet observer remains responsive.
            // The Task awaits completion so the setter and launchd state
            // stay consistent if the call throws.
            let newValue = launchAtLogin
            Task {
                await LaunchAtLoginManager.shared.setEnabled(newValue)
            }
        }
    }

    init() {
        self.launchAtLogin = UserDefaults.standard.object(forKey: SettingsKeys.launchAtLogin) as? Bool ?? false
    }
}
