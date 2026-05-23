//
//  AppearanceSettings.swift
//  Mio
//
//  Theme-scoped settings: launch-at-login.
//  Owns the launchd registration side-effect.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class AppearanceSettings: ObservableObject {

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            // Fire-and-forget main-actor task that drives the underlying
            // SMAppService registration. The actual launchd round-trip runs
            // on a detached utility-priority task inside `setEnabled` so
            // this didSet observer remains synchronous and responsive.
            // No cancellation: registration must complete or fail to keep
            // the persisted setting consistent with launchd state.
            let newValue = launchAtLogin
            Task {
                await LaunchAtLoginManager.shared.setEnabled(newValue)
            }
        }
    }

    init() {
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
    }
}
