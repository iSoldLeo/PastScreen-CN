//
//  EditorCompositeRenderer.swift
//  Mio
//
//  Module-09 async final compositor (M09-03 / Review1 F02).
//
//  唯一 concrete actor，消费 MainActor 冻结的 `EditorCompositeSnapshot`，用纯
//  CoreGraphics + CoreText 做全分辨率离屏合成，把重位图工作移出 MainActor。
//  它**不**使用 AppKit 文字渲染（`NSAttributedString`/`NSGraphicsContext`）、不读
//  `EditorState`、不使用 `Task.detached` / `@unchecked Sendable` / `@preconcurrency`
//  / `nonisolated(unsafe)`。
//
//  栅格绘制逐条移植自 `CommandRenderer` 的 CGContext 路径（本就是纯 CoreGraphics）；
//  pencil/mosaic 从快照的点序列重建 `CGPath`。文字层用 CoreText（`CTFont` + `CTLine`）
//  实现，基线/翻转语义为 origin = 左边中线、baseline = origin.y + capHeight/2。
//

import CoreGraphics
import CoreText
import Foundation

actor EditorCompositeRenderer {

    /// 全分辨率合成：原图 → 栅格命令时间序 → 文字层（永远在栅格之上）。
    /// 像素尺寸非法或 context/image 创建失败时 typed throw，不返回原图。
    func render(_ snapshot: EditorCompositeSnapshot) throws -> CaptureImage {
        try Task.checkCancellation()

        // F02 strict boundary: 不一致快照必须 typed-fail——绝不静默丢弃打码
        // （mosaic）命令而返回一张“成功”的未打码图（confidentiality）。
        for command in snapshot.commands {
            if case .mosaic(let points, _) = command {
                guard snapshot.pixelatedSource != nil else {
                    throw EditorCompositeError.missingPixelatedSource
                }
                guard !points.isEmpty else {
                    throw EditorCompositeError.invalidMosaicPath
                }
            }
        }

        let original = snapshot.original
        let scale = original.scale
        let pointSize = original.size
        let pixelWidth = Int(pointSize.width * scale)
        let pixelHeight = Int(pointSize.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw EditorCompositeError.invalidDimensions
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw EditorCompositeError.contextCreationFailed
        }

        // 全尺寸位图分配前检查取消：close/20s watchdog 取消后不再启动整次合成。
        try Task.checkCancellation()

        // scaleBy 让后续命令直接用 point 坐标，CGContext 自动渲染到 retina 像素。
        ctx.scaleBy(x: scale, y: scale)

        // 1. 原图（CGContext.draw 自带 Y 翻转，Y-up CTM 下正确）。
        let canvasRect = CGRect(origin: .zero, size: pointSize)
        ctx.draw(original.cgImage, in: canvasRect)

        // 2. 栅格命令 + 3. 文字层：翻到 Y-down（与 SwiftUI Canvas 一致）后绘制。
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pointSize.height)
        ctx.scaleBy(x: 1, y: -1)
        let pixelated = snapshot.pixelatedSource?.cgImage
        for command in snapshot.commands {
            try Task.checkCancellation()
            Self.draw(command, in: ctx, pixelatedSource: pixelated, canvasSize: pointSize)
        }
        for text in snapshot.texts {
            try Task.checkCancellation()
            Self.drawText(text, in: ctx)
        }
        ctx.restoreGState()

        try Task.checkCancellation()
        guard let image = ctx.makeImage() else {
            throw EditorCompositeError.imageCreationFailed
        }
        return try CaptureImage(validating: image, scale: scale)
    }

    // MARK: - Raster commands (ported from CommandRenderer CGContext path)

    private static func draw(
        _ command: CompositeCommand,
        in ctx: CGContext,
        pixelatedSource: CGImage?,
        canvasSize: CGSize
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch command {
        case .rectangle(let rect, let color, let thickness):
            ctx.setStrokeColor(color.cgColorValue)
            ctx.setLineWidth(Thickness.strokeWidth(thickness))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.strokePath()
        case .ellipse(let rect, let color, let thickness):
            ctx.setStrokeColor(color.cgColorValue)
            ctx.setLineWidth(Thickness.strokeWidth(thickness))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokeEllipse(in: rect)
        case .arrow(let from, let to, let color, let thickness):
            drawArrow(from: from, to: to, color: color, thickness: thickness, in: ctx)
        case .pencil(let points, let color, let thickness):
            guard let path = strokePath(from: points) else { return }
            ctx.setStrokeColor(color.cgColorValue)
            ctx.setLineWidth(Thickness.pencilWidth(thickness))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
        case .mosaic(let points, let thickness):
            guard let pixelatedSource, let path = strokePath(from: points) else { return }
            drawMosaic(path: path, thickness: thickness, pixelatedSource: pixelatedSource, canvasSize: canvasSize, in: ctx)
        }
    }

    private static func strokePath(from points: [CGPoint]) -> CGPath? {
        guard let first = points.first else { return nil }
        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    // MARK: - Arrow (geometry identical to CommandRenderer)

    private static func drawArrow(
        from: CGPoint,
        to: CGPoint,
        color: ColorRef,
        thickness: Int,
        in ctx: CGContext
    ) {
        let tipLength = Thickness.arrowheadLength(thickness)
        let tipAngle: CGFloat = .pi / 6
        let theta = atan2(to.y - from.y, to.x - from.x)
        let lineEnd = CGPoint(
            x: to.x - cos(theta) * tipLength * 0.4,
            y: to.y - sin(theta) * tipLength * 0.4
        )
        let tipLeft = CGPoint(
            x: to.x - cos(theta - tipAngle) * tipLength,
            y: to.y - sin(theta - tipAngle) * tipLength
        )
        let tipRight = CGPoint(
            x: to.x - cos(theta + tipAngle) * tipLength,
            y: to.y - sin(theta + tipAngle) * tipLength
        )

        ctx.setStrokeColor(color.cgColorValue)
        ctx.setFillColor(color.cgColorValue)
        ctx.setLineWidth(Thickness.strokeWidth(thickness))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        ctx.move(to: from)
        ctx.addLine(to: lineEnd)
        ctx.strokePath()

        ctx.move(to: to)
        ctx.addLine(to: tipLeft)
        ctx.addLine(to: tipRight)
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - Mosaic (clip stroke → draw pixelated source; Y-flip identical to CommandRenderer)

    private static func drawMosaic(
        path: CGPath,
        thickness: Int,
        pixelatedSource: CGImage,
        canvasSize: CGSize,
        in ctx: CGContext
    ) {
        let stroked = path.copy(
            strokingWithWidth: Thickness.mosaicWidth(thickness),
            lineCap: .square,
            lineJoin: .round,
            miterLimit: 10
        )
        ctx.saveGState()
        ctx.addPath(stroked)
        ctx.clip()
        // 抵消外层 Y-down 翻转，让 CGContext.draw 的内部翻转看到 Y-up 状态。
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(pixelatedSource, in: CGRect(origin: .zero, size: canvasSize))
        ctx.restoreGState()
    }

    // MARK: - Text (CoreText 文字层；no AppKit)

    private static func drawText(_ text: CompositeText, in ctx: CGContext) {
        guard !text.text.isEmpty else { return }

        let font = systemMediumFont(size: text.fontSize)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: text.color.cgColorValue
        ]
        guard let attributed = CFAttributedStringCreate(
            nil,
            text.text as CFString,
            attributes as CFDictionary
        ) else { return }
        let line = CTLineCreateWithAttributedString(attributed)

        // origin = 左边中线；baseline y 让大写字母视觉中线对齐 origin.y。
        let baselineY = text.origin.y + CTFontGetCapHeight(font) / 2

        // 当前 CTM 是 Y-down；局部平移到 baseline 后再翻 Y，让 CoreText 的 Y-up
        // 字形正向渲染。
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: text.origin.x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// medium 权重系统字体（CoreText，无 AppKit）。以系统 UI 字体为基础，套一个
    /// weight=0.23（≈ `NSFont.Weight.medium`）的 descriptor。
    private static func systemMediumFont(size: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
        let traits: [CFString: Any] = [kCTFontWeightTrait: 0.23]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }
}

// MARK: - ColorRef → CGColor (nonisolated, shared by the compositor)

extension ColorRef {
    /// 纯值 → `CGColor`（sRGB）。预设 RGB 与 `CommandRenderer` 一致。
    /// nonisolated：供 off-MainActor 的 `EditorCompositeRenderer` 使用。
    nonisolated var cgColorValue: CGColor {
        switch self {
        case .preset(let index):
            let presets: [(CGFloat, CGFloat, CGFloat)] = [
                (0.92, 0.20, 0.18),  // red
                (0.98, 0.65, 0.16),  // orange
                (0.20, 0.78, 0.42),  // green
                (0.10, 0.50, 0.96),  // blue
                (1.00, 1.00, 1.00),  // white
                (0.55, 0.55, 0.55),  // gray
                (0.00, 0.00, 0.00),  // black
            ]
            let idx = max(0, min(index, presets.count - 1))
            let (r, g, b) = presets[idx]
            return CGColor(red: r, green: g, blue: b, alpha: 1)
        case .sampled(let r, let g, let b, let a):
            return CGColor(red: r, green: g, blue: b, alpha: a)
        }
    }
}
