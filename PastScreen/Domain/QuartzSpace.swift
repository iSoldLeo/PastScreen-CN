//
//  QuartzSpace.swift
//  PastScreen
//
//  Coordinate conversion between AppKit (bottom-left origin) and Quartz (top-left origin).
//

import Foundation
import CoreGraphics

public enum QuartzSpace {
    public static var mainHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    public static func quartzPoint(fromAppKitGlobal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainHeight - point.y)
    }

    public static func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        let ay = mainHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: ay, width: rect.width, height: rect.height)
    }
}
