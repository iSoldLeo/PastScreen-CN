//
//  FrameRenderer.swift
//  Mio
//
//  Pure CoreGraphics/CoreText implementation of capture-frame-spec v2.2
//  (visual constants unchanged from v2.1).
//  AppKit resource lookup is performed once by FrameResourceLoader before this
//  renderer is called. Squircle geometry is ported from figma-squircle v1.1.0
//  (MIT), revision 45622dc2e9b23d69a44be673d15d1152c50df8d8.
//

import Foundation
import CoreGraphics
import CoreText

nonisolated enum FrameRenderer {
    static func compose(
        image: CaptureImage,
        configuration: ResolvedFrameConfiguration,
        resources: FrameResources
    ) throws -> CaptureImage {
        let style = configuration.theme.style
        let detectedInnerRadius = try detectInnerCornerRadius(
            image.cgImage,
            outputScale: image.scale
        )
        let composed = try composeImage(
            sourceImage: image.cgImage,
            sourcePointSize: image.size,
            outputScale: image.scale,
            style: style,
            customText: configuration.signature,
            resources: resources,
            detectedInnerRadius: detectedInnerRadius
        )
        do {
            return try CaptureImage(validating: composed, scale: image.scale)
        } catch let error as CaptureImage.ValidationError {
            throw ImageProcessingError.invalidSource(error)
        }
    }
}

// MARK: - Spec-locked scalar style

nonisolated private struct FrameRGBA: Sendable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        precondition([red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) })
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    func withAlpha(_ alpha: CGFloat) -> FrameRGBA {
        FrameRGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

nonisolated private struct FrameFontSpec: Sendable, Equatable {
    enum Weight: Sendable, Equatable {
        case regular
        case medium

        /// CoreText's normalized weight-trait values use the same scale as
        /// AppKit's system-font weights. Keeping the value explicit preserves
        /// the locked visual weight instead of using a remappable UI role.
        var traitValue: CGFloat {
            switch self {
            case .regular: 0
            case .medium: 0.23
            }
        }
    }

    let weight: Weight
    let pointSize: CGFloat

    init(weight: Weight, pointSize: CGFloat) {
        precondition(pointSize.isFinite && pointSize > 0)
        self.weight = weight
        self.pointSize = pointSize
    }
}

/// All stored fields are immutable scalar values. No AppKit object and no
/// unchecked Sendable conformance crosses into the renderer.
nonisolated private struct FrameStyle: Sendable {
    let padTop: CGFloat
    let padLeft: CGFloat
    let padRight: CGFloat
    let padBottom: CGFloat
    let cornerOffset: CGFloat
    let cornerSmoothing: CGFloat
    let cardBackground: FrameRGBA
    let cardInnerStrokeColor: FrameRGBA
    let cardInnerStrokeAlpha: CGFloat
    let cardOuterStrokeColor: FrameRGBA
    let cardOuterStrokeAlpha: CGFloat
    let cardOuterStrokeWidth: CGFloat
    let cardGlowColor: FrameRGBA
    let cardGlowAlpha: CGFloat
    let cardGlowBlur: CGFloat
    let screenshotShadowAlpha: CGFloat
    let screenshotShadowBlur: CGFloat
    let screenshotShadowOffsetY: CGFloat
    let screenshotEdgeHaloAlpha: CGFloat
    let screenshotEdgeHaloBlur: CGFloat
    let screenshotEdgeHaloColor: FrameRGBA
    let logoSize: CGFloat
    let logoCornerRadius: CGFloat
    let footerLogoTextSpacing: CGFloat
    let footerTitleFont: FrameFontSpec
    let footerTitleColor: FrameRGBA
    let footerCustomTextFont: FrameFontSpec
    let footerCustomTextColor: FrameRGBA
    let footerInnerPadX: CGFloat
}

nonisolated private extension ResolvedFrameTheme {
    var style: FrameStyle {
        let dark = self == .dark
        return FrameStyle(
            padTop: 28, padLeft: 28, padRight: 28, padBottom: 64,
            cornerOffset: 12,
            cornerSmoothing: 0.6,
            cardBackground: hex(dark ? "#1C1C1E" : "#FAFAFA"),
            cardInnerStrokeColor: hex(dark ? "#FFFFFF" : "#000000"),
            cardInnerStrokeAlpha: dark ? 0 : 0.04,
            cardOuterStrokeColor: hex(dark ? "#FFFFFF" : "#000000"),
            cardOuterStrokeAlpha: dark ? 0.13 : 0.08,
            cardOuterStrokeWidth: dark ? 1.5 : 1,
            cardGlowColor: hex(dark ? "#FFFFFF" : "#000000"),
            cardGlowAlpha: dark ? 0.15 : 0,
            cardGlowBlur: dark ? 6 : 0,
            screenshotShadowAlpha: dark ? 0 : 0.28,
            screenshotShadowBlur: dark ? 0 : 28,
            screenshotShadowOffsetY: dark ? 0 : 8,
            screenshotEdgeHaloAlpha: dark ? 0.675 : 0,
            screenshotEdgeHaloBlur: dark ? 15 : 0,
            screenshotEdgeHaloColor: hex("#FFFFFF"),
            logoSize: 30,
            logoCornerRadius: 30 * 0.2237,
            footerLogoTextSpacing: 11,
            footerTitleFont: FrameFontSpec(weight: .medium, pointSize: 17),
            footerTitleColor: hex(dark ? "#FFFFFF" : "#000000").withAlpha(0.88),
            footerCustomTextFont: FrameFontSpec(weight: .regular, pointSize: 12),
            footerCustomTextColor: hex(dark ? "#FFFFFF" : "#000000")
                .withAlpha(dark ? 0.50 : 0.45),
            footerInnerPadX: 8
        )
    }
}

nonisolated private func hex(_ string: String) -> FrameRGBA {
    var value = string
    if value.hasPrefix("#") { value.removeFirst() }
    precondition(value.count == 6 && UInt32(value, radix: 16) != nil)
    let rgb = UInt32(value, radix: 16)!
    return FrameRGBA(
        red: CGFloat((rgb >> 16) & 0xFF) / 255,
        green: CGFloat((rgb >> 8) & 0xFF) / 255,
        blue: CGFloat(rgb & 0xFF) / 255
    )
}

// MARK: - Inner corner detection

/// Rasterizes only the top-left alpha column used by the radius probe. This
/// reduces temporary storage from O(width * height) to O(min(width, height)).
nonisolated private func detectInnerCornerRadius(
    _ image: CGImage,
    outputScale: CGFloat
) throws -> CGFloat {
    let scanLimit = min(image.height / 2, image.width / 2, 320)
    guard scanLimit > 0 else { return 0 }
    guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: scanLimit)) else {
        throw ImageProcessingError.renderFailed(stage: .alphaProbe)
    }

    let bytesPerRow = 4
    var pixels = [UInt8](repeating: 0, count: scanLimit * bytesPerRow)
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(
        data: &pixels,
        width: 1,
        height: scanLimit,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
    ) else {
        throw ImageProcessingError.allocationFailed(stage: .alphaProbe)
    }

    context.translateBy(x: 0, y: CGFloat(scanLimit))
    context.scaleBy(x: 1, y: -1)
    context.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: scanLimit))

    for row in 0..<scanLimit where pixels[row * bytesPerRow + 3] > 128 {
        return CGFloat(row) / outputScale
    }
    return 0
}

// MARK: - Continuous (squircle) rounded rectangle path
//
// 移植自 phamfoo/figma-squircle (npm 1.1.0, MIT)。
// https://github.com/phamfoo/figma-squircle/blob/45622dc2e9b23d69a44be673d15d1152c50df8d8/src/draw.ts
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

nonisolated private func composeImage(
    sourceImage: CGImage,
    sourcePointSize: CGSize,
    outputScale: CGFloat,
    style: FrameStyle,
    customText: String,
    resources: FrameResources,
    detectedInnerRadius: CGFloat
) throws -> CGImage {
    let canvasPointWidth = style.padLeft + sourcePointSize.width + style.padRight
    let canvasPointHeight = style.padTop + sourcePointSize.height + style.padBottom
    let outerMargin: CGFloat = 64
    let renderPointWidth = canvasPointWidth + outerMargin * 2
    let renderPointHeight = canvasPointHeight + outerMargin * 2
    let pixelWidth = try checkedPixelDimension(renderPointWidth * outputScale)
    let pixelHeight = try checkedPixelDimension(renderPointHeight * outputScale)

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ImageProcessingError.allocationFailed(stage: .frameCanvas)
    }

    context.scaleBy(x: outputScale, y: outputScale)
    context.translateBy(x: outerMargin, y: outerMargin)

    let cardRect = CGRect(x: 0, y: 0, width: canvasPointWidth, height: canvasPointHeight)
    let cardCornerRadius = max(0, detectedInnerRadius + style.cornerOffset)
    let cardPath = continuousRoundedRectPath(
        in: cardRect,
        cornerRadius: cardCornerRadius,
        cornerSmoothing: style.cornerSmoothing
    )

    context.saveGState()
    if style.cardGlowAlpha > 0 {
        context.setShadow(
            offset: .zero,
            blur: style.cardGlowBlur,
            color: style.cardGlowColor.withAlpha(style.cardGlowAlpha).cgColor
        )
    }
    context.addPath(cardPath)
    context.setFillColor(style.cardBackground.cgColor)
    context.fillPath()
    context.restoreGState()

    if style.cardOuterStrokeAlpha > 0 && style.cardOuterStrokeWidth > 0 {
        context.saveGState()
        context.addPath(cardPath)
        context.setStrokeColor(style.cardOuterStrokeColor.withAlpha(style.cardOuterStrokeAlpha).cgColor)
        context.setLineWidth(style.cardOuterStrokeWidth)
        context.strokePath()
        context.restoreGState()
    }

    let imageRect = CGRect(
        x: style.padLeft,
        y: style.padBottom,
        width: sourcePointSize.width,
        height: sourcePointSize.height
    )

    if style.screenshotShadowAlpha > 0 {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -style.screenshotShadowOffsetY),
            blur: style.screenshotShadowBlur,
            color: hex("#000000").withAlpha(style.screenshotShadowAlpha).cgColor
        )
        context.draw(sourceImage, in: imageRect)
        context.restoreGState()
    }

    if style.screenshotEdgeHaloAlpha > 0 {
        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: style.screenshotEdgeHaloBlur,
            color: style.screenshotEdgeHaloColor.withAlpha(style.screenshotEdgeHaloAlpha).cgColor
        )
        context.draw(sourceImage, in: imageRect)
        context.restoreGState()
    }

    context.draw(sourceImage, in: imageRect)

    if style.cardInnerStrokeAlpha > 0 {
        context.saveGState()
        let inset: CGFloat = 0.5
        context.addPath(continuousRoundedRectPath(
            in: cardRect.insetBy(dx: inset, dy: inset),
            cornerRadius: max(0, cardCornerRadius - inset),
            cornerSmoothing: style.cornerSmoothing
        ))
        context.setStrokeColor(style.cardInnerStrokeColor.withAlpha(style.cardInnerStrokeAlpha).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()
    }

    try drawFooter(
        in: context,
        canvasWidth: canvasPointWidth,
        style: style,
        customText: customText,
        logo: resources.logo
    )

    guard let fullImage = context.makeImage() else {
        throw ImageProcessingError.renderFailed(stage: .frameCanvas)
    }

    let outputPixelWidth = try checkedPixelDimension(canvasPointWidth * outputScale)
    let outputPixelHeight = try checkedPixelDimension(canvasPointHeight * outputScale)
    let cropRect = CGRect(
        x: try checkedPixelDimension(outerMargin * outputScale),
        y: try checkedPixelDimension(outerMargin * outputScale),
        width: outputPixelWidth,
        height: outputPixelHeight
    )
    guard let cropped = fullImage.cropping(to: cropRect) else {
        throw ImageProcessingError.renderFailed(stage: .finalCopy)
    }

    return try exactSizeCopy(
        cropped,
        width: outputPixelWidth,
        height: outputPixelHeight,
        colorSpace: colorSpace
    )
}

nonisolated private func checkedPixelDimension(_ value: CGFloat) throws -> Int {
    let rounded = value.rounded(.toNearestOrAwayFromZero)
    guard rounded.isFinite,
          rounded > 0,
          let dimension = Int(exactly: rounded)
    else {
        throw ImageProcessingError.allocationFailed(stage: .frameCanvas)
    }
    return dimension
}

nonisolated private func exactSizeCopy(
    _ image: CGImage,
    width: Int,
    height: Int,
    colorSpace: CGColorSpace
) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw ImageProcessingError.allocationFailed(stage: .finalCopy)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let copied = context.makeImage() else {
        throw ImageProcessingError.renderFailed(stage: .finalCopy)
    }
    return copied
}

nonisolated private func drawFooter(
    in context: CGContext,
    canvasWidth: CGFloat,
    style: FrameStyle,
    customText: String,
    logo: CGImage
) throws {
    let centerY = style.padBottom / 2
    let logoRect = CGRect(
        x: style.padLeft + style.footerInnerPadX,
        y: centerY - style.logoSize / 2,
        width: style.logoSize,
        height: style.logoSize
    )
    context.saveGState()
    context.addPath(continuousRoundedRectPath(
        in: logoRect,
        cornerRadius: style.logoCornerRadius,
        cornerSmoothing: style.cornerSmoothing
    ))
    context.clip()
    context.draw(logo, in: logoRect)
    context.restoreGState()

    let titleFont = try makeFont(style.footerTitleFont)
    let titleLine = makeLine(
        "Mio",
        font: titleFont,
        color: style.footerTitleColor.cgColor
    )
    let titleX = logoRect.maxX + style.footerLogoTextSpacing
    let titleY = centerY - CTFontGetCapHeight(titleFont) / 2
    context.textPosition = CGPoint(x: titleX, y: titleY)
    CTLineDraw(titleLine, context)

    let trimmed = customText.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }

    let titleWidth = CGFloat(CTLineGetTypographicBounds(titleLine, nil, nil, nil))
    let signatureLeft = titleX + titleWidth + style.footerLogoTextSpacing
    let signatureRight = canvasWidth - style.padRight - style.footerInnerPadX
    let availableWidth = signatureRight - signatureLeft
    guard availableWidth > 0 else { return }

    let signatureFont = try makeFont(style.footerCustomTextFont)
    let fullLine = makeLine(
        trimmed,
        font: signatureFont,
        color: style.footerCustomTextColor.cgColor
    )
    let token = makeLine(
        "…",
        font: signatureFont,
        color: style.footerCustomTextColor.cgColor
    )
    let line: CTLine
    if CGFloat(CTLineGetTypographicBounds(fullLine, nil, nil, nil)) <= availableWidth {
        line = fullLine
    } else if let truncated = CTLineCreateTruncatedLine(fullLine, Double(availableWidth), .end, token) {
        line = truncated
    } else {
        throw ImageProcessingError.renderFailed(stage: .frameCanvas)
    }

    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    context.textPosition = CGPoint(
        x: signatureRight - lineWidth,
        y: centerY - CTFontGetCapHeight(signatureFont) / 2
    )
    CTLineDraw(line, context)
}

nonisolated private func makeFont(_ spec: FrameFontSpec) throws -> CTFont {
    guard let systemFont = CTFontCreateUIFontForLanguage(.system, spec.pointSize, nil) else {
        throw ImageProcessingError.renderFailed(stage: .frameCanvas)
    }
    let descriptor = CTFontDescriptorCreateWithAttributes([
        kCTFontTraitsAttribute: [
            kCTFontWeightTrait: spec.weight.traitValue,
        ],
    ] as CFDictionary)
    return CTFontCreateCopyWithAttributes(
        systemFont,
        spec.pointSize,
        nil,
        descriptor
    )
}

nonisolated private func makeLine(
    _ text: String,
    font: CTFont,
    color: CGColor
) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
}
