//
//  TextRenderer.swift
//  Mio
//
//  完成时把矢量文字标注合成到最终 CGImage（spec §6.6 / §7）。
//
//  锚点对齐：origin 是「左边中线」，源图 point 空间。
//  NSAttributedString.draw(at:) 用「左下角 baseline」，需要计算偏移：
//      baselineY = origin.y + capHeight / 2
//  让大写字母视觉中线对齐 origin。
//

import AppKit
import CoreGraphics

@MainActor
enum TextRenderer {
    static func draw(_ annotation: TextAnnotation, in ctx: CGContext) {
        guard !annotation.text.isEmpty else { return }

        let nsColor = nsColor(annotation.color)
        let font = NSFont.systemFont(ofSize: annotation.fontSize, weight: .medium)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nsColor
        ]
        let attrString = NSAttributedString(string: annotation.text, attributes: attrs)

        // 文字基线 y 计算：让 origin.y 对齐大写字母视觉中线
        // capHeight 是大写字母从 baseline 到顶部的高度
        let baselineOffset = font.capHeight / 2
        let baselineY = annotation.origin.y + baselineOffset

        // 当前 CGContext 在 FinalRenderer 已切到 Y-down 坐标系（与 SwiftUI 一致），
        // NSAttributedString.draw(at:) 在 NSGraphicsContext 内会自动用「文本基线在
        // at 点」的语义。但 NSGraphicsContext 默认假设 Y-up（AppKit 坐标系）。
        // 为安全：先 push NSGraphicsContext 显式翻转 Y，让 AppKit 文字渲染走正向。
        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = nsCtx

        attrString.draw(at: CGPoint(x: annotation.origin.x, y: baselineY))

        NSGraphicsContext.restoreGraphicsState()
    }

    private static func nsColor(_ ref: ColorRef) -> NSColor {
        switch ref {
        case .preset(let i):
            let presets: [(CGFloat, CGFloat, CGFloat)] = [
                (0.92, 0.20, 0.18),
                (0.98, 0.65, 0.16),
                (0.20, 0.78, 0.42),
                (0.10, 0.50, 0.96),
                (1.00, 1.00, 1.00),
                (0.55, 0.55, 0.55),
                (0.00, 0.00, 0.00),
            ]
            let idx = max(0, min(i, presets.count - 1))
            let (r, g, b) = presets[idx]
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        case .sampled(let r, let g, let b, let a):
            return NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
        }
    }
}
