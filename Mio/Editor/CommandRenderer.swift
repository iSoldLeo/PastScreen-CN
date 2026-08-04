//
//  CommandRenderer.swift
//  Mio
//
//  把 DrawCommand / DraftSnapshot 渲染到 SwiftUI GraphicsContext 或 CGContext。
//
//  两套对外 API（GraphicsContext 给 Canvas 闭包用；CGContext 给完成时离屏
//  合成用），核心 path / color / lineWidth 计算共享 helper，确保编辑预览
//  与最终图像素一致。
//

import SwiftUI
import CoreGraphics

@MainActor
enum CommandRenderer {

    /// 椭圆 drafting 期间的外接矩形辅助框颜色（#39C5BB 哔哩哔哩青）。
    /// 仅在 drafting 阶段渲染，松开鼠标 commit 后即消失，不入命令栈、不入最终图。
    private static let ellipseGuideColor = Color(red: 0x39 / 255.0, green: 0xC5 / 255.0, blue: 0xBB / 255.0)

    // MARK: - SwiftUI Canvas (drawing preview)

    /// `fullPixelated` 是 `@autoclosure`，只在 `.mosaic` 分支里求值。
    ///
    /// 调用方（EditorView 的 Canvas 闭包、FinalRenderer）对每条命令都传
    /// `state.fullPixelated`，而它现在是惰性生成的（EditorState 内注释）。若这里按
    /// 值接收，每帧、每条命令都会触发一次求值 —— 首次求值就是 4K ~30ms 的整图
    /// pixellate，惰性化的收益全部作废。用 autoclosure 把求值推迟到真正需要底图
    /// 的那个 case，调用点写法完全不用改。
    static func draw(
        _ cmd: DrawCommand,
        in ctx: inout GraphicsContext,
        fullPixelated: @autoclosure () -> CGImage,
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
            drawMosaicSwiftUI(
                path: path,
                thickness: thickness,
                fullPixelated: fullPixelated(),   // 惰性求值只在此分支发生
                canvasSize: canvasSize,
                in: &ctx
            )
        }
    }

    /// `fullPixelated` 同为 `@autoclosure`，理由见上一个 `draw`。
    static func draw(
        _ draft: DraftSnapshot,
        in ctx: inout GraphicsContext,
        fullPixelated: @autoclosure () -> CGImage,
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
            drawMosaicSwiftUI(
                path: mutablePath,
                thickness: thickness,
                fullPixelated: fullPixelated(),   // 惰性求值只在此分支发生
                canvasSize: canvasSize,
                in: &ctx
            )
        }
    }

    // MARK: - CGContext (final compose)

    /// `fullPixelated` 同为 `@autoclosure`，理由见 GraphicsContext 版本的 `draw`。
    static func draw(
        _ cmd: DrawCommand,
        in ctx: CGContext,
        fullPixelated: @autoclosure () -> CGImage,
        canvasSize: CGSize
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch cmd {
        case .rectangle(_, let rect, let color, let thickness):
            // 微圆角矩形：4pt continuous（spec §6.1）
            ctx.setStrokeColor(cgColor(color))
            ctx.setLineWidth(Thickness.strokeWidth(thickness))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let roundedPath = CGPath(
                roundedRect: rect,
                cornerWidth: 4,
                cornerHeight: 4,
                transform: nil
            )
            ctx.addPath(roundedPath)
            ctx.strokePath()
        case .ellipse(_, let rect, let color, let thickness):
            ctx.setStrokeColor(cgColor(color))
            ctx.setLineWidth(Thickness.strokeWidth(thickness))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokeEllipse(in: rect)
        case .arrow(_, let from, let to, let color, let thickness):
            drawArrow(from: from, to: to, color: color, thickness: thickness, in: ctx)
        case .pencil(_, let path, let color, let thickness):
            ctx.setStrokeColor(cgColor(color))
            ctx.setLineWidth(Thickness.pencilWidth(thickness))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
        case .mosaic(_, let path, let thickness):
            drawMosaicCG(
                path: path,
                thickness: thickness,
                fullPixelated: fullPixelated(),   // 惰性求值只在此分支发生
                canvasSize: canvasSize,
                in: ctx
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

    private static func drawArrow(
        from: CGPoint,
        to: CGPoint,
        color: ColorRef,
        thickness: Int,
        in ctx: CGContext
    ) {
        let geom = arrowGeometry(from: from, to: to, thickness: thickness)

        ctx.setStrokeColor(cgColor(color))
        ctx.setFillColor(cgColor(color))
        ctx.setLineWidth(Thickness.strokeWidth(thickness))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        ctx.move(to: from)
        ctx.addLine(to: geom.lineEnd)
        ctx.strokePath()

        ctx.move(to: geom.tipApex)
        ctx.addLine(to: geom.tipLeft)
        ctx.addLine(to: geom.tipRight)
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - Mosaic

    /// SwiftUI Canvas 版本：用 path stroke 出一段宽方头描边作为 clip mask，
    /// 把 fullPixelated 的对应区域画到画布。
    /// canvasSize 是「源图 point 空间」尺寸（与 CGContext 版本一致），让 Canvas
    /// 预览与 FinalRenderer 合成在同一坐标系下行为一致。
    private static func drawMosaicSwiftUI(
        path: CGPath,
        thickness: Int,
        fullPixelated: CGImage,
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
            // Image(decorative:scale:) 的 scale 让 SwiftUI 把 fullPixelated 当成
            // canvasSize 物理尺寸的图像（fullPixelated.width 是像素，canvasSize.width
            // 是 point；scale = pixel / point）。这样画到 (0, 0, canvasSize) 时
            // 自然贴合源图坐标系。
            let imageScale = canvasSize.width > 0
                ? CGFloat(fullPixelated.width) / canvasSize.width
                : 1
            layer.draw(
                Image(decorative: fullPixelated, scale: imageScale),
                in: CGRect(origin: .zero, size: canvasSize)
            )
        }
    }

    /// CGContext 版本（合成）：path stroke → clip → 画 fullPixelated。
    /// canvasSize 是 point 尺寸（与 GraphicsContext 一致）。
    ///
    /// 调用方（FinalRenderer）已切到 Y-down CTM，但 `ctx.draw(image, in:)` 内部
    /// 会再做一次 Y 翻转，导致马赛克贴出来上下颠倒。在内部包一次反向翻转抵消。
    private static func drawMosaicCG(
        path: CGPath,
        thickness: Int,
        fullPixelated: CGImage,
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
        // 抵消 FinalRenderer 的 Y-down 翻转：再翻一次让 CGContext.draw 的内部翻转
        // 看到的是 Y-up 状态，画出来的图与命令朝向一致。
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(
            fullPixelated,
            in: CGRect(origin: .zero, size: canvasSize)
        )
        ctx.restoreGState()
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

    private static func cgColor(_ ref: ColorRef) -> CGColor {
        switch ref {
        case .preset(let i):
            // SwiftUI Color 直接拿不到 CGColor（macOS 14+ 才有 .resolve）
            // 用预设的 RGB 值直接构造 CGColor 避免依赖。
            let presets: [(CGFloat, CGFloat, CGFloat)] = [
                (0.92, 0.20, 0.18),  // red
                (0.98, 0.65, 0.16),  // orange
                (0.20, 0.78, 0.42),  // green
                (0.10, 0.50, 0.96),  // blue
                (1.00, 1.00, 1.00),  // white
                (0.55, 0.55, 0.55),  // gray
                (0.00, 0.00, 0.00),  // black
            ]
            let idx = max(0, min(i, presets.count - 1))
            let (r, g, b) = presets[idx]
            return CGColor(red: r, green: g, blue: b, alpha: 1)
        case .sampled(let r, let g, let b, let a):
            return CGColor(red: r, green: g, blue: b, alpha: a)
        }
    }
}
