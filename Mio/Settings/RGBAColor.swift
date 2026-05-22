//
//  RGBAColor.swift
//  Mio
//
//  Codable, Sendable color value used by AppSettings (window border)
//  and CaptureConfiguration (cross-layer DTO). All conversions go
//  through sRGB. Pure value type; no actor isolation required.
//

import Foundation
import AppKit
import SwiftUI

public struct RGBAColor: Codable, Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.r = Double(color.redComponent)
        self.g = Double(color.greenComponent)
        self.b = Double(color.blueComponent)
        self.a = Double(color.alphaComponent)
    }

    init?(cgColor: CGColor) {
        guard let nsColor = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }
        self.init(nsColor: nsColor)
    }

    var cgColor: CGColor? {
        NSColor(
            calibratedRed: CGFloat(r),
            green: CGFloat(g),
            blue: CGFloat(b),
            alpha: CGFloat(a)
        ).cgColor
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
