//
//  QuartzSpace.swift
//  Mio
//
//  Coordinate conversion between AppKit (bottom-left origin) and Quartz (top-left origin).
//

import Foundation
import CoreGraphics
import ApplicationServices

nonisolated public enum QuartzSpace {
    /// Height of the main display in Quartz coordinates.
    /// Quartz global coordinates use (0,0) at the top-left of the main display framebuffer.
    /// Returns 0 on headless systems; callers should validate before conversion.
    public static var mainHeight: CGFloat {
        let displayID = CGMainDisplayID()
        guard displayID != 0 else { return 0 }
        return CGDisplayBounds(displayID).height
    }

    /// Convert an AppKit-global point (bottom-left origin) to Quartz (top-left origin).
    /// Uses the main display height as the reference; assumes the point is on the main display.
    public static func quartzPoint(fromAppKitGlobal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainHeight - point.y)
    }

    /// Convert a Quartz rect (top-left origin) to an AppKit screen rect (bottom-left origin).
    /// Uses the main display height as the reference; correct for windows on any display
    /// because Quartz global Y is always relative to the main display's top edge.
    public static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        let ay = mainHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: ay, width: rect.width, height: rect.height)
    }
}
