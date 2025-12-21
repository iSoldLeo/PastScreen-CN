//
//  LiquidGlassComponents.swift
//  PastScreen
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

// MARK: - Liquid Glass Background

struct LiquidGlassBackground: View {
    var material: Material = .ultraThinMaterial
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(material)
    }
}

// MARK: - Glass Button

struct GlassButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let icon {
                    Image(systemName: icon)
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .glassContainer(
            material: isHovered ? .regularMaterial : .thinMaterial,
            cornerRadius: 10,
            borderOpacity: 0.16,
            shadowOpacity: 0.06
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Vibrancy Text

struct VibrancyText: View {
    let text: String
    let font: Font

    init(_ text: String, font: Font = .body) {
        self.text = text
        self.font = font
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.primary)
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

// MARK: - Blur Overlay (for screenshot selection)

struct BlurOverlay: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Dimension Label (Glass style)

struct DimensionLabel: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(String(format: "%.0f", width))
            Image(systemName: "xmark")
                .font(.caption)
            Text(String(format: "%.0f", height))
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassContainer(material: .ultraThinMaterial, cornerRadius: 8, borderOpacity: 0.18, shadowOpacity: 0.08)
    }
}

// MARK: - Spring Animation Helper

extension Animation {
    static var smoothSpring: Animation {
        .spring(response: 0.4, dampingFraction: 0.75, blendDuration: 0.3)
    }

    static var quickSpring: Animation {
        .spring(response: 0.1, dampingFraction: 0.8, blendDuration: 0.1)
    }
}
