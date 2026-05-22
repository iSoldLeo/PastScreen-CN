//
//  AppearanceSettings.swift
//  Mio
//
//  Theme-scoped settings: app language, Dock icon visibility,
//  launch-at-login. Owns the Bundle.setAppLanguage swizzle trigger
//  and the launchd registration side-effect.
//
//  Phase 6A theme split: the umbrella `AppSettings` aggregates this
//  store via `AppSettings.shared.appearance`. SwiftUI views inject it
//  with `@EnvironmentObject var appearance: AppearanceSettings`.
//

import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class AppearanceSettings: ObservableObject {

    /// Tracks whether init has finished, so the antarctic chirp does not
    /// fire when the value is loaded from UserDefaults at startup.
    private var isInitialized = false

    @Published var appLanguage: AppLanguage {
        didSet {
            let previous = oldValue
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            applyAppLanguage()
            if isInitialized,
               appLanguage == .antarctic,
               previous != .antarctic {
                AppLanguage.playAntarcticChirp()
            }
        }
    }

    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            // Fire-and-forget: launchd registration runs on a detached task
            // inside `setEnabled`. We do not await here because the didSet
            // observer is part of a synchronous main-actor setter.
            //
            // Owner: AppearanceSettings (held by AppSettings.shared, process-lifetime).
            // Priority: inherits .utility from setEnabled's detached task.
            // Cancellation: not propagated; launchd registration must run
            // to completion to stay consistent with the persisted setting.
            let newValue = launchAtLogin
            Task { @MainActor in
                await LaunchAtLoginManager.shared.setEnabled(newValue)
            }
        }
    }

    init() {
        if let savedLanguage = UserDefaults.standard.string(forKey: "appLanguage"),
           let language = AppLanguage(rawValue: savedLanguage) {
            self.appLanguage = language
        } else {
            self.appLanguage = .system
        }

        self.showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? false
        self.launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false

        self.isInitialized = true
        applyAppLanguage()
    }

    /// Apply the currently selected language to the global AppleLanguages
    /// preference and the Bundle swizzle. Called from `init` (no chirp) and
    /// from `appLanguage.didSet` (with chirp guard).
    private func applyAppLanguage() {
        switch appLanguage {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            Bundle.setAppLanguage(nil)
        default:
            UserDefaults.standard.set([appLanguage.rawValue], forKey: "AppleLanguages")
            Bundle.setAppLanguage(appLanguage.rawValue)
        }
    }
}
