//
//  FrameRenderer.swift
//  Mio
//
//  画框输出合成 — 把窗口截图嵌入"作品署名"画框 PNG。
//
//  本文件是 docs/capture-frame-spec.md v2.1 的代码实现。**改这里 = 改产品契约**：
//  必须先升 spec 版本号，再改源码、再改 sandbox（scripts/frame_preview/main.swift）。
//
//  路径：
//    路径 A 窗口点击直出 → CaptureCoordinator.handleSelectedWindow → compose
//    路径 A 区域拖框直出 → CaptureCoordinator.handleSelectedRect → compose
//    路径 D 编辑器 finish → EditorWindowController.finish → compose
//
//  不覆盖：路径 B 全屏截图、路径 A 窗口 fallback（壁纸 crop）。
//
//  核心设计：
//    - 纯函数（nonisolated enum + static 方法）
//    - 输入 / 输出都是 Sendable CaptureImage
//    - 性能：~10–30ms 合成（普通窗口尺寸），不影响热路径（用户点选 → 输出）
//    - 圆角检测：alpha 通道扫描，禁止硬编码假设值
//    - 圆角形态：phamfoo/figma-squircle (MIT) 移植，smoothing = 0.6
//
//  Squircle 算法移植自 phamfoo/figma-squircle (npm 1.1.0, MIT)。
//  https://github.com/phamfoo/figma-squircle
//  本身又是 MartinRGB 的 JS 实现，最终源 Figma blog "Desperately Seeking Squircles"。
//

import Foundation
import AppKit
import CoreGraphics
import CoreText

// MARK: - Public API

nonisolated public enum FrameRenderer {

    /// 主入口。`config.enabled == false` 时原样返回，零开销。
    ///
    /// 调用方：CaptureCoordinator (路径 A 直出) 与 EditorWindowController (路径 D)。
    /// 调用方在 @MainActor 上下文调用此方法，但本函数内部完全 nonisolated；
    /// 跨 actor 边界传 CaptureImage 已经是 Sendable，无需额外处理。
    public static func compose(
        image: CaptureImage,
        config: Configuration
    ) -> CaptureImage {
        guard config.enabled else { return image }

        let style = config.resolvedTheme.style
        let detectedInnerRadius = detectInnerCornerRadius(
            image.cgImage,
            outputScale: image.scale
        )

        guard let composed = composeImage(
            sourceImage: image.cgImage,
            sourcePointSize: image.size,
            outputScale: image.scale,
            style: style,
            customText: config.customText,
            detectedInnerRadius: detectedInnerRadius
        ) else {
            // 合成失败 → 原样返回。极少数发生，例如 CGContext 创建失败。
            return image
        }

        // 输出尺寸：源图 point 尺寸 + padding；scale 与原图一致
        let outputPointSize = CGSize(
            width: style.padLeft + image.size.width + style.padRight,
            height: style.padTop + image.size.height + style.padBottom
        )
        return CaptureImage(
            cgImage: composed,
            scale: image.scale,
            size: outputPointSize
        )
    }

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let enabled: Bool
        /// 已 clamp 到 40 字符以内（spec §3.5 字符上限）。空字符串则 footer 右下不画文字。
        public let customText: String
        /// 主题 .auto 已经在调用方（CaptureCoordinator）解析为 .light / .dark。
        /// FrameRenderer 不读 NSAppearance，与 main-actor 隔离解耦。
        public let resolvedTheme: ResolvedTheme

        public enum ResolvedTheme: Sendable {
            case light
            case dark
        }

        public init(enabled: Bool, customText: String, resolvedTheme: ResolvedTheme) {
            self.enabled = enabled
            self.customText = String(customText.prefix(40))
            self.resolvedTheme = resolvedTheme
        }
    }
}

// MARK: - Style (visual constants — locked by docs/capture-frame-spec.md v2.1)

/// 一套画框视觉数值。**所有数值都是 spec v2.1 锁定值**，改这里 = 改产品契约。
///
/// SAFETY: `@unchecked Sendable`：所有存储字段为 `let`；其中 `NSFont` 与
/// `CGColor` 跨线程读取由 Apple 文档保证安全（CoreText/CoreGraphics 全是
/// 不可变 CF/Cocoa 类型）。本结构体只在编译期常量初始化中使用，不暴露
/// 可变 API；运行期等价于"两份永久不变的样式表"。
nonisolated private struct FrameStyle: @unchecked Sendable {
    // 留白
    let padTop: CGFloat
    let padLeft: CGFloat
    let padRight: CGFloat
    let padBottom: CGFloat

    // 卡片几何
    let cornerOffset: CGFloat            // outer = inner + offset
    let cornerSmoothing: CGFloat
    let cardBackground: CGColor
    let cardInnerStrokeColor: CGColor
    let cardInnerStrokeAlpha: CGFloat
    let cardOuterStrokeColor: CGColor
    let cardOuterStrokeAlpha: CGFloat
    let cardOuterStrokeWidth: CGFloat

    // 卡片光晕（暗色版用，浅色版 alpha=0）
    let cardGlowColor: CGColor
    let cardGlowAlpha: CGFloat
    let cardGlowBlur: CGFloat

    // 截图柔阴影（浅色版用，暗色版 alpha=0）
    let screenshotShadowAlpha: CGFloat
    let screenshotShadowBlur: CGFloat
    let screenshotShadowOffsetY: CGFloat

    // 截图 alpha 边界 halo（暗色版用，浅色版 alpha=0）
    let screenshotEdgeHaloAlpha: CGFloat
    let screenshotEdgeHaloBlur: CGFloat
    let screenshotEdgeHaloColor: CGColor

    // Footer
    let logoSize: CGFloat
    let logoCornerRadius: CGFloat
    let footerLogoTextSpacing: CGFloat
    let footerTitle: String
    let footerTitleFont: NSFont
    let footerTitleColor: CGColor
    let footerCustomTextFont: NSFont
    let footerCustomTextColor: CGColor
    let footerInnerPadX: CGFloat
}

// MARK: - Spec-locked styles

extension FrameRenderer.Configuration.ResolvedTheme {
    fileprivate nonisolated var style: FrameStyle {
        switch self {
        case .light: return FrameStyle.lightV1
        case .dark:  return FrameStyle.darkV2_1
        }
    }
}

nonisolated extension FrameStyle {

    /// 浅色 v1（capture-frame-spec.md §3.1–§3.7）
    static let lightV1 = FrameStyle(
        padTop: 28, padLeft: 28, padRight: 28, padBottom: 64,
        cornerOffset: 12,
        cornerSmoothing: 0.6,
        cardBackground: hex("#FAFAFA"),
        cardInnerStrokeColor: hex("#000000"),
        cardInnerStrokeAlpha: 0.04,
        cardOuterStrokeColor: hex("#000000"),
        cardOuterStrokeAlpha: 0.08,
        cardOuterStrokeWidth: 1,
        cardGlowColor: hex("#000000"),
        cardGlowAlpha: 0,
        cardGlowBlur: 0,
        screenshotShadowAlpha: 0.28,
        screenshotShadowBlur: 28,
        screenshotShadowOffsetY: 8,
        screenshotEdgeHaloAlpha: 0,
        screenshotEdgeHaloBlur: 0,
        screenshotEdgeHaloColor: hex("#FFFFFF"),
        logoSize: 30,
        logoCornerRadius: 30 * 0.2237,
        footerLogoTextSpacing: 11,
        footerTitle: "Mio",
        footerTitleFont: NSFont.systemFont(ofSize: 17, weight: .medium),
        footerTitleColor: hex("#000000").withMioAlpha(0.88),
        footerCustomTextFont: NSFont.systemFont(ofSize: 12, weight: .regular),
        footerCustomTextColor: hex("#000000").withMioAlpha(0.45),
        footerInnerPadX: 8
    )

    /// 暗色 v2.1（capture-frame-spec.md §3.8）
    static let darkV2_1 = FrameStyle(
        padTop: 28, padLeft: 28, padRight: 28, padBottom: 64,
        cornerOffset: 12,
        cornerSmoothing: 0.6,
        cardBackground: hex("#1C1C1E"),
        cardInnerStrokeColor: hex("#FFFFFF"),
        cardInnerStrokeAlpha: 0,                 // 暗色版不画
        cardOuterStrokeColor: hex("#FFFFFF"),
        cardOuterStrokeAlpha: 0.13,              // 1.5pt #FFF 13% 隔离线
        cardOuterStrokeWidth: 1.5,
        cardGlowColor: hex("#FFFFFF"),
        cardGlowAlpha: 0.15,                     // Glow2
        cardGlowBlur: 6,
        screenshotShadowAlpha: 0,                // 暗色版不画截图柔阴影
        screenshotShadowBlur: 0,
        screenshotShadowOffsetY: 0,
        screenshotEdgeHaloAlpha: 0.675,          // Halo15x
        screenshotEdgeHaloBlur: 15,
        screenshotEdgeHaloColor: hex("#FFFFFF"),
        logoSize: 30,
        logoCornerRadius: 30 * 0.2237,
        footerLogoTextSpacing: 11,
        footerTitle: "Mio",
        footerTitleFont: NSFont.systemFont(ofSize: 17, weight: .medium),
        footerTitleColor: hex("#FFFFFF").withMioAlpha(0.88),
        footerCustomTextFont: NSFont.systemFont(ofSize: 12, weight: .regular),
        footerCustomTextColor: hex("#FFFFFF").withMioAlpha(0.50),
        footerInnerPadX: 8
    )
}

// MARK: - Color helpers

nonisolated private func hex(_ hex: String) -> CGColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else {
        return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }
    let r = CGFloat((v >> 16) & 0xFF) / 255.0
    let g = CGFloat((v >> 8)  & 0xFF) / 255.0
    let b = CGFloat( v        & 0xFF) / 255.0
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

extension CGColor {
    /// 加 alpha 后的副本。命名 `withMioAlpha` 避免与 SDK 内部 SPI 冲突。
    fileprivate nonisolated func withMioAlpha(_ a: CGFloat) -> CGColor {
        return self.copy(alpha: a) ?? self
    }
}

// MARK: - Inner corner detection (alpha scan)

/// 从 alpha 通道反推窗口截图的圆角半径（point）。
///
/// 假定输入图是紧贴窗口边界的 RGBA（SCK 用 `desktopIndependentWindow` +
/// `backgroundColor = .clear` + `ignoreShadowsSingleWindow = true` 拿到的那种）。
/// 沿截图左上角 `x=0` 列从 `y=0` 向下扫描，第一个 alpha > 50% 的像素 y 值 =
/// 像素空间圆角半径。除以 outputScale 得 point。
///
/// 鲁棒性：
///   - 直角窗口（无圆角） → 返回 0
///   - 完全实心矩形（如全屏图、无 alpha） → 返回 0
///   - 抗锯齿渐变 → 取 alpha=128 处，即圆弧的几何中心
///
/// 不允许用任何"假设值"（macOS 15 ≈ 10pt / macOS 26 ≈ 16pt 等）替代检测——
/// 应用自绘窗口圆角差异巨大，硬编码必错。
nonisolated private func detectInnerCornerRadius(_ image: CGImage, outputScale: CGFloat) -> CGFloat {
    let w = image.width
    let h = image.height
    let bytesPerRow = w * 4
    let cs = CGColorSpaceCreateDeviceRGB()
    var pixels = [UInt8](repeating: 0, count: w * h * 4)

    // 显式 RGBA 内存布局（避免字节序歧义）
    let bitmapInfo: UInt32 =
        CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    guard let ctx = CGContext(
        data: &pixels,
        width: w, height: h,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: cs,
        bitmapInfo: bitmapInfo
    ) else { return 0 }

    // 翻转 y 轴让 buffer 第 0 行 = 视觉顶行
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    let alphaThreshold: UInt8 = 128
    let scanLimit = min(h / 2, w / 2, 320)

    for y in 0..<scanLimit {
        let alphaIdx = y * bytesPerRow + 3
        if pixels[alphaIdx] > alphaThreshold {
            return CGFloat(y) / outputScale
        }
    }
    return 0
}

// MARK: - Continuous (squircle) rounded rectangle path
//
// 移植自 phamfoo/figma-squircle (npm 1.1.0, MIT)。
// https://github.com/phamfoo/figma-squircle/blob/main/src/draw.ts
//
// 核心思想：每个角 = bezier → 真圆弧 → bezier 三段：
//   1. 第一段三次贝塞尔：从直线段（曲率 0）渐增到圆弧入口（曲率 = 1/r）
//   2. 中间真圆弧：曲率恒定 = 1/r
//   3. 第二段三次贝塞尔：从圆弧出口渐降到下一条直线（曲率 0）
//
// smoothing = 0   → 退化为纯 90° 圆弧（与 CGPath 默认行为一致）
// smoothing = 0.6 → iOS / macOS 系统级 squircle（spec 锁定）
// smoothing = 1.0 → 整角全是贝塞尔（最 squircle）
//
// preserveSmoothing = false（与 Figma 当前行为对齐）：当 p > budget clamp smoothing。

nonisolated private struct SquircleCornerParams {
    let a: CGFloat
    let b: CGFloat
    let c: CGFloat
    let d: CGFloat
    let p: CGFloat
    let cornerRadius: CGFloat
    let arcSectionLength: CGFloat
}

nonisolated private func toRadians(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }

nonisolated private func squirclePathParams(
    cornerRadius: CGFloat,
    cornerSmoothing: CGFloat,
    roundingAndSmoothingBudget: CGFloat
) -> SquircleCornerParams {
    var smoothing = cornerSmoothing
    var p = (1 + smoothing) * cornerRadius

    if cornerRadius > 0 {
        let maxSmoothing = roundingAndSmoothingBudget / cornerRadius - 1
        smoothing = min(smoothing, max(0, maxSmoothing))
        p = min(p, roundingAndSmoothingBudget)
    }

    let arcMeasure = 90 * (1 - smoothing)
    let arcSectionLength = sin(toRadians(arcMeasure / 2)) * cornerRadius * sqrt(2)

    let angleAlpha = (90 - arcMeasure) / 2
    let p3p4 = cornerRadius * tan(toRadians(angleAlpha / 2))

    let angleBeta = 45 * smoothing
    let c = p3p4 * cos(toRadians(angleBeta))
    let d = c * tan(toRadians(angleBeta))

    let b = (p - arcSectionLength - c - d) / 3
    let a = 2 * b

    return SquircleCornerParams(
        a: a, b: b, c: c, d: d, p: p,
        cornerRadius: cornerRadius,
        arcSectionLength: arcSectionLength
    )
}

/// macOS / iOS 系统级"流畅化"圆角矩形路径。
///
/// 当 `cornerRadius * (1 + smoothing) > min(width, height) / 2` 时，按 budget 自动
/// clamp，避免极端尺寸退化。`cornerRadius == 0` 时退化为直角矩形。
nonisolated private func continuousRoundedRectPath(
    in rect: CGRect,
    cornerRadius: CGFloat,
    cornerSmoothing: CGFloat
) -> CGPath {
    let path = CGMutablePath()
    let width = rect.width
    let height = rect.height

    let budget = min(width, height) / 2
    let r = min(cornerRadius, budget)

    if r <= 0 {
        path.addRect(rect)
        return path
    }

    let pp = squirclePathParams(
        cornerRadius: r,
        cornerSmoothing: cornerSmoothing,
        roundingAndSmoothingBudget: budget
    )

    let minX = rect.minX
    let minY = rect.minY
    let maxX = rect.maxX
    let maxY = rect.maxY

    let a = pp.a, b = pp.b, c = pp.c, d = pp.d, p = pp.p
    let arcLen = pp.arcSectionLength
    let cr = pp.cornerRadius

    path.move(to: CGPoint(x: maxX - p, y: minY))

    // 右上
    path.addCurve(
        to:       CGPoint(x: maxX - p + (a + b + c), y: minY + d),
        control1: CGPoint(x: maxX - p + a,           y: minY),
        control2: CGPoint(x: maxX - p + (a + b),     y: minY)
    )
    let trArcStart = CGPoint(x: maxX - p + (a + b + c), y: minY + d)
    let trArcEnd   = CGPoint(x: trArcStart.x + arcLen, y: trArcStart.y + arcLen)
    addArcSegment(path: path, from: trArcStart, to: trArcEnd, radius: cr)
    path.addCurve(
        to:       CGPoint(x: trArcEnd.x + d, y: trArcEnd.y + (a + b + c)),
        control1: CGPoint(x: trArcEnd.x + d, y: trArcEnd.y + c),
        control2: CGPoint(x: trArcEnd.x + d, y: trArcEnd.y + (b + c))
    )

    path.addLine(to: CGPoint(x: maxX, y: maxY - p))

    // 右下
    path.addCurve(
        to:       CGPoint(x: maxX - d, y: maxY - p + (a + b + c)),
        control1: CGPoint(x: maxX,     y: maxY - p + a),
        control2: CGPoint(x: maxX,     y: maxY - p + (a + b))
    )
    let brArcStart = CGPoint(x: maxX - d, y: maxY - p + (a + b + c))
    let brArcEnd   = CGPoint(x: brArcStart.x - arcLen, y: brArcStart.y + arcLen)
    addArcSegment(path: path, from: brArcStart, to: brArcEnd, radius: cr)
    path.addCurve(
        to:       CGPoint(x: brArcEnd.x - (a + b + c), y: brArcEnd.y + d),
        control1: CGPoint(x: brArcEnd.x - c,           y: brArcEnd.y + d),
        control2: CGPoint(x: brArcEnd.x - (b + c),     y: brArcEnd.y + d)
    )

    path.addLine(to: CGPoint(x: minX + p, y: maxY))

    // 左下
    path.addCurve(
        to:       CGPoint(x: minX + p - (a + b + c), y: maxY - d),
        control1: CGPoint(x: minX + p - a,           y: maxY),
        control2: CGPoint(x: minX + p - (a + b),     y: maxY)
    )
    let blArcStart = CGPoint(x: minX + p - (a + b + c), y: maxY - d)
    let blArcEnd   = CGPoint(x: blArcStart.x - arcLen, y: blArcStart.y - arcLen)
    addArcSegment(path: path, from: blArcStart, to: blArcEnd, radius: cr)
    path.addCurve(
        to:       CGPoint(x: blArcEnd.x - d, y: blArcEnd.y - (a + b + c)),
        control1: CGPoint(x: blArcEnd.x - d, y: blArcEnd.y - c),
        control2: CGPoint(x: blArcEnd.x - d, y: blArcEnd.y - (b + c))
    )

    path.addLine(to: CGPoint(x: minX, y: minY + p))

    // 左上
    path.addCurve(
        to:       CGPoint(x: minX + d, y: minY + p - (a + b + c)),
        control1: CGPoint(x: minX,     y: minY + p - a),
        control2: CGPoint(x: minX,     y: minY + p - (a + b))
    )
    let tlArcStart = CGPoint(x: minX + d, y: minY + p - (a + b + c))
    let tlArcEnd   = CGPoint(x: tlArcStart.x + arcLen, y: tlArcStart.y - arcLen)
    addArcSegment(path: path, from: tlArcStart, to: tlArcEnd, radius: cr)
    path.addCurve(
        to:       CGPoint(x: tlArcEnd.x + (a + b + c), y: tlArcEnd.y - d),
        control1: CGPoint(x: tlArcEnd.x + c,           y: tlArcEnd.y - d),
        control2: CGPoint(x: tlArcEnd.x + (b + c),     y: tlArcEnd.y - d)
    )

    path.closeSubpath()
    return path
}

/// 真圆弧那段。已知 from / to 两点 + 半径 r，重建 ≤90° 圆弧。
///
/// figma-squircle 几何里圆心始终在矩形**内部**——chord 方向逆时针旋 90° 即指向
/// 内部。CGPath addArc 的 clockwise 参数按 Y-up 语义；圆心在内部时，按角度
/// 增加方向（CCW in math）走是短弧，对应 SVG sweep=1（Y-down 视觉顺时针）。
nonisolated private func addArcSegment(
    path: CGMutablePath,
    from: CGPoint,
    to: CGPoint,
    radius: CGFloat
) {
    let dx = to.x - from.x
    let dy = to.y - from.y
    let chord = sqrt(dx * dx + dy * dy)
    if chord <= 0 || radius <= 0 {
        path.addLine(to: to)
        return
    }
    let halfChord = min(chord / 2, radius)
    let h = sqrt(max(0, radius * radius - halfChord * halfChord))
    let mx = (from.x + to.x) / 2
    let my = (from.y + to.y) / 2
    // 法向量 = chord 方向逆时针旋 90° = (-dy, dx) / chord
    let nx = -dy / chord
    let ny =  dx / chord
    let center = CGPoint(x: mx + nx * h, y: my + ny * h)

    let startAngle = atan2(from.y - center.y, from.x - center.x)
    let endAngle   = atan2(to.y - center.y,   to.x - center.x)

    path.addArc(
        center: center,
        radius: radius,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: false
    )
}

// MARK: - Compose

/// 主合成函数。返回带画框的 CGImage。
///
/// 渲染步骤（Y-up 坐标系）：
///   1. card 背景（continuous squircle）
///   2. card 外描边（隔离线）
///   3. 截图柔阴影（浅色版）
///   4. 截图自身 alpha 边界 halo（暗色版）
///   5. 截图本体
///   6. 卡片内描边
///   7. footer（logo + "Mio" + 自定义文字）
///   8. 裁掉外溢 margin（让阴影 / halo 不被 bitmap 边界硬切）
///
/// 渲染时多分配 64pt 外溢空间，给 blur ≤ 28pt 的阴影 / halo 留渗出范围；
/// 完成后裁回原尺寸。这样输出 PNG 大小 = 卡片真实尺寸（28 + W + 28, 28 + H + 64）。
nonisolated private func composeImage(
    sourceImage: CGImage,
    sourcePointSize: CGSize,
    outputScale: CGFloat,
    style: FrameStyle,
    customText: String,
    detectedInnerRadius: CGFloat
) -> CGImage? {
    let canvasPointWidth  = style.padLeft + sourcePointSize.width  + style.padRight
    let canvasPointHeight = style.padTop  + sourcePointSize.height + style.padBottom

    // 给 shadow / halo / glow 留外溢空间。最大 blur ≈ 28pt + outerStrokeWidth/2 + 安全裕量
    let outerMargin: CGFloat = 64
    let renderPointWidth  = canvasPointWidth  + outerMargin * 2
    let renderPointHeight = canvasPointHeight + outerMargin * 2
    let pixelWidth  = Int(renderPointWidth  * outputScale)
    let pixelHeight = Int(renderPointHeight * outputScale)

    // 解析外圆角
    let minSidePadding = min(style.padTop, style.padLeft, style.padRight)
    _ = minSidePadding   // 保留供未来 .concentricToPadding 策略；当前用 cornerOffset
    let cardCornerRadius = max(0, detectedInnerRadius + style.cornerOffset)

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
    ctx.scaleBy(x: outputScale, y: outputScale)
    // 平移让原 (0,0) 对应 outerMargin，footer 排版坐标无须改
    ctx.translateBy(x: outerMargin, y: outerMargin)

    let cardRect = CGRect(x: 0, y: 0, width: canvasPointWidth, height: canvasPointHeight)
    let cardPath = continuousRoundedRectPath(
        in: cardRect,
        cornerRadius: cardCornerRadius,
        cornerSmoothing: style.cornerSmoothing
    )

    // 1. 卡片背景（如有 glow，借 setShadow 同时画出"卡片光晕"）
    if style.cardGlowAlpha > 0 {
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero,
            blur: style.cardGlowBlur,
            color: style.cardGlowColor.withMioAlpha(style.cardGlowAlpha)
        )
        ctx.addPath(cardPath)
        ctx.setFillColor(style.cardBackground)
        ctx.fillPath()
        ctx.restoreGState()
    } else {
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.setFillColor(style.cardBackground)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. 卡片外描边（隔离线）
    if style.cardOuterStrokeAlpha > 0 && style.cardOuterStrokeWidth > 0 {
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.setStrokeColor(style.cardOuterStrokeColor.withMioAlpha(style.cardOuterStrokeAlpha))
        ctx.setLineWidth(style.cardOuterStrokeWidth)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 截图位置（Y-up）
    let imageRect = CGRect(
        x: style.padLeft,
        y: style.padBottom,
        width: sourcePointSize.width,
        height: sourcePointSize.height
    )

    // 3. 截图柔阴影（浅色版）
    if style.screenshotShadowAlpha > 0 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -style.screenshotShadowOffsetY),
            blur: style.screenshotShadowBlur,
            color: hex("#000000").withMioAlpha(style.screenshotShadowAlpha)
        )
        ctx.draw(sourceImage, in: imageRect)
        ctx.restoreGState()
    }

    // 4. 截图 alpha 边界 halo（暗色版）
    if style.screenshotEdgeHaloAlpha > 0 {
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero,
            blur: style.screenshotEdgeHaloBlur,
            color: style.screenshotEdgeHaloColor.withMioAlpha(style.screenshotEdgeHaloAlpha)
        )
        ctx.draw(sourceImage, in: imageRect)
        ctx.restoreGState()
    }

    // 5. 截图本体
    ctx.saveGState()
    ctx.draw(sourceImage, in: imageRect)
    ctx.restoreGState()

    // 6. 卡片内描边
    if style.cardInnerStrokeAlpha > 0 {
        ctx.saveGState()
        let inset: CGFloat = 0.5
        let strokeRect = cardRect.insetBy(dx: inset, dy: inset)
        let strokePath = continuousRoundedRectPath(
            in: strokeRect,
            cornerRadius: max(0, cardCornerRadius - inset),
            cornerSmoothing: style.cornerSmoothing
        )
        ctx.addPath(strokePath)
        ctx.setStrokeColor(style.cardInnerStrokeColor.withMioAlpha(style.cardInnerStrokeAlpha))
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 7. Footer
    drawFooter(in: ctx, canvasWidth: canvasPointWidth, style: style, customText: customText)

    // 8. 裁回 canvas 尺寸
    guard let fullImage = ctx.makeImage() else { return nil }
    let cropPixelRect = CGRect(
        x: outerMargin * outputScale,
        y: outerMargin * outputScale,
        width: canvasPointWidth * outputScale,
        height: canvasPointHeight * outputScale
    )
    return fullImage.cropping(to: cropPixelRect)
}

nonisolated private func drawFooter(
    in ctx: CGContext,
    canvasWidth: CGFloat,
    style: FrameStyle,
    customText: String
) {
    let footerCenterY = style.padBottom / 2.0

    // 左侧：logo + "Mio"
    var leftCursor = style.padLeft + style.footerInnerPadX

    if let logoImage = MioLogoImage.cached() {
        let logoRect = CGRect(
            x: leftCursor,
            y: footerCenterY - style.logoSize / 2,
            width: style.logoSize,
            height: style.logoSize
        )
        ctx.saveGState()
        let mask = continuousRoundedRectPath(
            in: logoRect,
            cornerRadius: style.logoCornerRadius,
            cornerSmoothing: style.cornerSmoothing
        )
        ctx.addPath(mask)
        ctx.clip()
        ctx.draw(logoImage, in: logoRect)
        ctx.restoreGState()
        leftCursor = logoRect.maxX + style.footerLogoTextSpacing
    }

    // "Mio" 文字（CoreText）
    let titleAttr = NSAttributedString(
        string: style.footerTitle,
        attributes: [
            .font: style.footerTitleFont,
            .foregroundColor: NSColor(cgColor: style.footerTitleColor) ?? NSColor.black
        ]
    )
    let titleLine = CTLineCreateWithAttributedString(titleAttr)
    let titleY = footerCenterY - style.footerTitleFont.capHeight / 2
    ctx.textPosition = CGPoint(x: leftCursor, y: titleY)
    CTLineDraw(titleLine, ctx)

    // 右侧：自定义文字
    let trimmed = customText.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    // customText 已在 Configuration.init 内 prefix(40) clamp；这里 belt-and-suspenders
    let clamped = trimmed.count > 40
        ? String(trimmed.prefix(40)) + "…"
        : trimmed

    let customAttr = NSAttributedString(
        string: clamped,
        attributes: [
            .font: style.footerCustomTextFont,
            .foregroundColor: NSColor(cgColor: style.footerCustomTextColor) ?? NSColor.gray
        ]
    )
    let customLine = CTLineCreateWithAttributedString(customAttr)
    let customWidth = CTLineGetTypographicBounds(customLine, nil, nil, nil)
    let customX = canvasWidth - style.padRight - style.footerInnerPadX - CGFloat(customWidth)
    let customY = footerCenterY - style.footerCustomTextFont.capHeight / 2
    ctx.textPosition = CGPoint(x: customX, y: customY)
    CTLineDraw(customLine, ctx)
}

// MARK: - Logo cache

/// 从 asset catalog 加载 Mio logo。第一次使用时缓存为 CGImage，之后零开销。
///
/// SAFETY: nonisolated(unsafe) 是 write-once-then-read 模式：
///   1. 缓存只在第一次调用时写入
///   2. 写入后不再修改（仅读取）
///   3. CGImage 是不可变 CF 类型，跨线程读安全
/// `cached()` 加锁保护初始化阶段；之后的快路径只读 cgImageCache。
nonisolated private final class MioLogoImage {
    nonisolated(unsafe) static var cgImageCache: CGImage?
    static let initLock = NSLock()

    static func cached() -> CGImage? {
        // 快路径：已初始化
        if let img = cgImageCache { return img }

        initLock.lock()
        defer { initLock.unlock() }

        // 双重检查
        if let img = cgImageCache { return img }

        // 完整 app logo（branding/mio-logo-1024.png 拷贝到 Assets.xcassets 内的
        // FrameLogo imageset）。1024×1024 RGB（无 alpha），通过 squircle mask 切出
        // macOS app icon 形状。
        //
        // 找不到 → 返回 nil → drawFooter 跳过 logo，只显示 "Mio" 文字。
        // 不 fallback 到 MenuBarIcon 之类——单色菜单栏图标在画框里看错位，遮盖
        // "asset 配置错误"问题反而更糟。
        guard let nsImage = NSImage(named: "FrameLogo") else { return nil }

        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        cgImageCache = cgImage
        return cgImage
    }
}
