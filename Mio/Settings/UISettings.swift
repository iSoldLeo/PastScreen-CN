//
//  UISettings.swift
//  Mio
//
//  UI-scoped settings: window border styling and the per-display
//  frozen-window snapshot limit. Consumed by ImageRenderService /
//  CapturePipeline (window border) and the future ScreenshotService
//  re-integration (frozen window limit).
//
//  Phase 6A theme split: aggregated under `AppSettings.shared.ui`.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class UISettings: ObservableObject {

    // Defaults for window border (off-white with a hint of gray)
    private static let defaultBorderColor = RGBAColor(r: 0.97, g: 0.97, b: 0.97, a: 1.0)
    private static let defaultBorderWidth: Double = 10
    private static let defaultBorderCornerRadius: Double = 22

    /// Lower bound for the frozen-window snapshot count per display. The
    /// public projection clamps on the way in so subscribers never observe
    /// a transient out-of-range value (a didSet self-assignment would emit
    /// twice).
    private static let minFrozenWindowLimit = 5

    @Published var windowBorderEnabled: Bool {
        didSet {
            UserDefaults.standard.set(windowBorderEnabled, forKey: "windowBorderEnabled")
        }
    }

    @Published var windowBorderWidth: Double {
        didSet {
            UserDefaults.standard.set(windowBorderWidth, forKey: "windowBorderWidth")
        }
    }

    @Published var windowBorderCornerRadius: Double {
        didSet {
            UserDefaults.standard.set(windowBorderCornerRadius, forKey: "windowBorderCornerRadius")
        }
    }

    @Published var windowBorderColor: RGBAColor {
        didSet {
            if let encoded = try? JSONEncoder().encode(windowBorderColor) {
                UserDefaults.standard.set(encoded, forKey: "windowBorderColor")
            }
        }
    }

    /// Backing storage for `frozenWindowLimitPerDisplay`. Always holds a
    /// clamped value (≥ minFrozenWindowLimit).
    @Published private var _frozenWindowLimitPerDisplay: Int

    var frozenWindowLimitPerDisplay: Int {
        get { _frozenWindowLimitPerDisplay }
        set {
            let clamped = max(Self.minFrozenWindowLimit, newValue)
            guard clamped != _frozenWindowLimitPerDisplay else { return }
            _frozenWindowLimitPerDisplay = clamped
            UserDefaults.standard.set(clamped, forKey: "frozenWindowLimitPerDisplay")
        }
    }

    init() {
        self.windowBorderEnabled = UserDefaults.standard.object(forKey: "windowBorderEnabled") as? Bool ?? true
        self.windowBorderWidth = UserDefaults.standard.object(forKey: "windowBorderWidth") as? Double ?? Self.defaultBorderWidth
        self.windowBorderCornerRadius = UserDefaults.standard.object(forKey: "windowBorderCornerRadius") as? Double ?? Self.defaultBorderCornerRadius

        if let data = UserDefaults.standard.data(forKey: "windowBorderColor"),
           let decoded = try? JSONDecoder().decode(RGBAColor.self, from: data) {
            self.windowBorderColor = decoded
        } else {
            self.windowBorderColor = Self.defaultBorderColor
        }

        let storedWindowLimit = UserDefaults.standard.integer(forKey: "frozenWindowLimitPerDisplay")
        if storedWindowLimit > 0 {
            self._frozenWindowLimitPerDisplay = max(Self.minFrozenWindowLimit, storedWindowLimit)
        } else {
            self._frozenWindowLimitPerDisplay = 10
        }
    }
}
