//
//  FinalRenderer.swift
//  Mio
//
//  完成按钮触发的离屏合成（spec §7）。
//
//  - 创建物理像素尺寸的 CGContext
//  - scaleBy 后所有命令直接用 point 坐标
//  - 顺序：原图 → 栅格命令时间序 → 文字层（永远在栅格之上）
//  - 复用 CommandRenderer 的 CGContext 渲染路径，确保编辑预览与最终图像素一致
//

import CoreGraphics

@MainActor
enum FinalRenderer {
    static func render(state: EditorState) -> CGImage? {
        let original = state.original
        let scale = original.scale
        let pointSize = original.size
        let pixelWidth = Int(pointSize.width * scale)
        let pixelHeight = Int(pointSize.height * scale)

        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // scaleBy 让所有后续命令直接用 point 坐标，CGContext 自动渲染到 retina 像素
        ctx.scaleBy(x: scale, y: scale)

        // 1. 原图：CGContext.draw 内部自带 Y 翻转，Y-up CTM 下结果正确
        let canvasRect = CGRect(origin: .zero, size: pointSize)
        ctx.draw(original.cgImage, in: canvasRect)

        // 2. 栅格命令：Y-down 坐标系（与 SwiftUI Canvas 一致），需翻转 CTM 后再画。
        //    包在独立 saveGState 内，画完后还原；这样后续若加 text 层也能用同一翻转。
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pointSize.height)
        ctx.scaleBy(x: 1, y: -1)
        for cmd in state.commands {
            CommandRenderer.draw(
                cmd,
                in: ctx,
                fullPixelated: state.fullPixelated,
                canvasSize: pointSize
            )
        }
        // 3. 文字层（在同一 Y-down CTM 下画 — TextRenderer 内部用
        //    NSGraphicsContext(flipped: true) 让 AppKit 文字渲染走正向）
        for text in state.textAnnotations {
            TextRenderer.draw(text, in: ctx)
        }
        ctx.restoreGState()

        return ctx.makeImage()
    }
}
