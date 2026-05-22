//
//  LiquidGlassComponents.swift
//  Mio
//
//  Reusable Liquid Glass UI components for macOS 14+
//

import SwiftUI
import AppKit

// MARK: - Shared Glass Styling

private struct GlassContainerStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var material: Material
    var cornerRadius: CGFloat
    var showBorder: Bool
    var borderOpacity: Double
    var shadowOpacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(fillStyle, in: shape)
            .clipShape(shape)
            .overlay {
                if showBorder {
                    shape
                        .strokeBorder(borderStyle, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(shadowOpacity), radius: 14, x: 0, y: 8)
    }

    private var fillStyle: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        }
        return AnyShapeStyle(material)
    }

    private var borderStyle: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .separatorColor).opacity(0.7))
        }
        return AnyShapeStyle(Color.white.opacity(borderOpacity))
    }
}

extension View {
    func glassContainer(
        material: Material = .regularMaterial,
        cornerRadius: CGFloat = 12,
        showBorder: Bool = true,
        borderOpacity: Double = 0.14,
        shadowOpacity: Double = 0.10
    ) -> some View {
        modifier(
            GlassContainerStyle(
                material: material,
                cornerRadius: cornerRadius,
                showBorder: showBorder,
                borderOpacity: borderOpacity,
                shadowOpacity: shadowOpacity
            )
        )
    }
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .glassContainer(material: .regularMaterial, cornerRadius: 12)
    }
}
