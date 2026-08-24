//
//  FrameResources.swift
//  Mio
//
//  The sole AppKit-to-CoreGraphics resource boundary for frame rendering.
//  AppServices calls this once on MainActor and injects the immutable result.
//

import AppKit
import CoreGraphics

nonisolated struct FrameResources: Sendable {
    let logo: CGImage
}

@MainActor
enum FrameResourceLoader {
    static func load() -> FrameResources? {
        guard let image = NSImage(named: "FrameLogo") else { return nil }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let logo = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }
        return FrameResources(logo: logo)
    }
}
