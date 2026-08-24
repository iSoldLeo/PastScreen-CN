//
//  CommandRenderer.swift
//  Mio
//
//  把 DrawCommand / DraftSnapshot 渲染到 SwiftUI GraphicsContext（Canvas 预览）。
//
//  只负责编辑期预览；完成时的全分辨率离屏合成由 EditorCompositeRenderer actor
//  负责（几何/线宽常量共享 Thickness，确保预览与最终图一致）。
//

import SwiftUI
import CoreGraphics

@MainActor
enum CommandRenderer {

    /// 椭圆 drafting 期间的外接矩形辅助框颜色（#39C5BB 哔哩哔哩青）。
    /// 仅在 drafting 阶段渲染，松开鼠标 commit 后即消失，不入命令栈、不入最终图。
    private static let ellipseGuideColor = Color(red: 0x39 / 255.0, green: 0xC5 / 255.0, blue: 0xBB / 255.0)

    // MARK: - SwiftUI Canvas (drawing preview)

    /// Mosaic source is optional only because non-mosaic commands never need
    /// it. EditorState blocks creation of mosaic drafts/commands until ready;
    /// the EditorCompositeRenderer actor independently rejects an inconsistent snapshot.
    static func draw(
        _ cmd: DrawCommand,
        in ctx: inout GraphicsContext,
        pixelatedSource: CGImage?,
        canvasSize: CGSize
    ) {
        switch cmd {
        case .rectangle(_, let rect, let color, let thickness):
            // 微圆角矩形（spec §6.1）：4pt continuous，比直角更柔和但不像圆角
            let path = Path(roundedRect: rect, cornerSize: CGSize(width: 4, height: 4), style: .continuous)
            ctx.stroke(
                path,
                with: .color(swiftUIColor(color)),
                style: StrokeStyle(
                    lineWidth: Thickness.strokeWidth(thickness),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        case .ellipse(_, let rect, let color, let thickness):
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(swiftUIColor(color)),
                style: StrokeStyle(
                    lineWidth: Thickness.strokeWidth(thickness),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        case .arrow(_, let from, let to, let color, let thickness):
            drawArrow(from: from, to: to, color: color, thickness: thickness, in: &ctx)
        case .pencil(_, let path, let color, let thickness):
            ctx.stroke(
                Path(path),
                with: .color(swiftUIColor(color)),
                style: StrokeStyle(
                    lineWidth: Thickness.pencilWidth(thickness),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        case .mosaic(_, let path, let thickness):
            guard let pixelatedSource else { return }
            drawMosaicSwiftUI(
                path: path,
                thickness: thickness,
                pixelatedSource: pixelatedSource,
                canvasSize: canvasSize,
                in: &ctx
            )
        }
    }

    static func draw(
        _ draft: DraftSnapshot,
        in ctx: inout GraphicsContext,
        pixelatedSource: CGImage?,
        canvasSize: CGSize
    ) {
        switch draft {
        case .rectangle(let rect, let color, let thickness):
            ctx.stroke(
                Path(roundedRect: rect, cornerSize: CGSize(width: 4, height: 4), style: .continuous),
                with: .color(swiftUIColor(color)),
                style: StrokeStyle(lineWidth: Thickness.strokeWidth(thickness), lineCap: .round, lineJoin: .round)
            )
        case .ellipse(let rect, let color, let thickness):
            // 椭圆绘制时显示外接矩形虚线辅助框，方便用户定位（drafting 期 only，
            // 松开手指 commit 成 DrawCommand 时不带辅助框，最终图也不含）。
            ctx.stroke(
                Path(rect),
                with: .color(ellipseGuideColor),
                style: StrokeStyle(
                    lineWidth: Thickness.strokeWidth(0),  // 矩形最细一档
                    dash: [4, 3]
                )
            )
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(swiftUIColor(color)),
                style: StrokeStyle(lineWidth: Thickness.strokeWidth(thickness), lineCap: .round, lineJoin: .round)
            )
        case .arrow(let from, let to, let color, let thickness):
            drawArrow(from: from, to: to, color: color, thickness: thickness, in: &ctx)
        case .pencil(let mutablePath, let color, let thickness):
            ctx.stroke(
                Path(mutablePath),
                with: .color(swiftUIColor(color)),
                style: StrokeStyle(lineWidth: Thickness.pencilWidth(thickness), lineCap: .round, lineJoin: .round)
            )
        case .mosaic(let mutablePath, let thickness):
            guard let pixelatedSource else { return }
            drawMosaicSwiftUI(
                path: mutablePath,
                thickness: thickness,
                pixelatedSource: pixelatedSource,
                canvasSize: canvasSize,
                in: &ctx
            )
        }
    }

    // MARK: - Arrow

    /// 箭头：起点 = 尾，终点 = 尖；尖部三角与线粗弱关联。
    private static func arrowGeometry(
        from: CGPoint,
        to: CGPoint,
        thickness: Int
    ) -> (lineEnd: CGPoint, tipLeft: CGPoint, tipRight: CGPoint, tipApex: CGPoint) {
        let tipLength = Thickness.arrowheadLength(thickness)
        let tipAngle: CGFloat = .pi / 6  // 30°
        let dx = to.x - from.x
        let dy = to.y - from.y
        let theta = atan2(dy, dx)

        // 主线段终点缩短一点，让出三角尖位置
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
        return (lineEnd, tipLeft, tipRight, to)
    }

    private static func drawArrow(
        from: CGPoint,
        to: CGPoint,
        color: ColorRef,
        thickness: Int,
        in ctx: inout GraphicsContext
    ) {
        let geom = arrowGeometry(from: from, to: to, thickness: thickness)

        var line = Path()
        line.move(to: from)
        line.addLine(to: geom.lineEnd)

        var head = Path()
        head.move(to: geom.tipApex)
        head.addLine(to: geom.tipLeft)
        head.addLine(to: geom.tipRight)
        head.closeSubpath()

        let style = StrokeStyle(
            lineWidth: Thickness.strokeWidth(thickness),
            lineCap: .round,
            lineJoin: .round
        )
        let fill = swiftUIColor(color)
        ctx.stroke(line, with: .color(fill), style: style)
        ctx.fill(head, with: .color(fill))
    }

    // MARK: - Mosaic

    /// SwiftUI Canvas 版本：用 path stroke 出一段宽方头描边作为 clip mask，
    /// 把 pixelatedSource 的对应区域画到画布。
    /// canvasSize 是「源图 point 空间」尺寸（与最终合成一致），让 Canvas 预览
    /// 与 EditorCompositeRenderer 合成在同一坐标系下行为一致。
    private static func drawMosaicSwiftUI(
        path: CGPath,
        thickness: Int,
        pixelatedSource: CGImage,
        canvasSize: CGSize,
        in ctx: inout GraphicsContext
    ) {
        let stroked = path.copy(
            strokingWithWidth: Thickness.mosaicWidth(thickness),
            lineCap: .square,
            lineJoin: .round,
            miterLimit: 10
        )
        ctx.drawLayer { layer in
            layer.clip(to: Path(stroked))
            // Image(decorative:scale:) 的 scale 让 SwiftUI 把 pixelatedSource 当成
            // canvasSize 物理尺寸的图像（pixelatedSource.width 是像素，canvasSize.width
            // 是 point；scale = pixel / point）。这样画到 (0, 0, canvasSize) 时
            // 自然贴合源图坐标系。
            let imageScale = canvasSize.width > 0
                ? CGFloat(pixelatedSource.width) / canvasSize.width
                : 1
            layer.draw(
                Image(decorative: pixelatedSource, scale: imageScale),
                in: CGRect(origin: .zero, size: canvasSize)
            )
        }
    }

    // MARK: - Color

    private static func swiftUIColor(_ ref: ColorRef) -> Color {
        switch ref {
        case .preset(let i):
            return editorPresetColors[max(0, min(i, editorPresetColors.count - 1))].color
        case .sampled(let r, let g, let b, let a):
            return Color(red: r, green: g, blue: b, opacity: a)
        }
    }
}
