//
//  Capture.swift
//  Mio
//
//  Module-08 staged feedback seam. Module-03 session ownership and module-04
//  acquisition live in their dedicated Capture files.
//

import AppKit
import Foundation

/// Resolve the semantic frame preference only when a final render request is
/// being constructed. Capture and Editor share this one MainActor boundary.
@MainActor
func resolvedFrameApplication(from preference: CaptureFramePreference) -> FrameApplication {
    guard preference.isEnabled else { return .none }
    let resolvedTheme: ResolvedFrameTheme = switch preference.theme {
    case .alwaysLight:
        .light
    case .alwaysDark:
        .dark
    case .auto:
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .dark
            : .light
    }
    return .apply(ResolvedFrameConfiguration(
        theme: resolvedTheme,
        signature: preference.signature
    ))
}

// Module 03 session orchestration lives in Capture/CaptureController.swift.
// This file retains acquisition (04) frame resolution; module-08 completion
// feedback lives in Capture/CaptureFeedback.swift.
