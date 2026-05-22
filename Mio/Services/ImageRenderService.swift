//
//  ImageRenderService.swift
//  Mio
//
//  Actor for image post-processing (borders, etc.)
//  CALayer.render(in:) is executed inside actor isolation.
//

import Foundation
import QuartzCore
// TODO: Remove @preconcurrency once Apple marks AppKit types as Sendable.
@preconcurrency import AppKit

public actor ImageRenderService: ImageRendering {
    public init() {}

    public func addBorder(to image: CaptureImage, config: CaptureConfiguration) async throws -> CaptureImage {
        let cgImage = image.cgImage
        let scale = image.scale
        let borderPoints = CGFloat(config.windowBorderWidth)
        let cornerRadiusPoints = CGFloat(config.windowBorderCornerRadius)

        guard borderPoints > 0 else {
            return image
        }

        let borderColor = await MainActor.run {
            config.windowBorderColor.cgColor ?? CGColor(gray: 1, alpha: 1)
        }
        let borderPixels = max(1, Int(ceil(borderPoints * scale)))
        let newWidth = cgImage.width + borderPixels * 2
        let newHeight = cgImage.height + borderPixels * 2
        let cornerRadiusPixels = max(CGFloat(0), cornerRadiusPoints * scale)

        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CaptureError("Unable to determine color space for border rendering")
        }

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError("Failed to create graphics context for border rendering")
        }

        let shapeLayer = CALayer()
        shapeLayer.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
        shapeLayer.backgroundColor = borderColor
        shapeLayer.cornerRadius = cornerRadiusPixels
        shapeLayer.cornerCurve = .continuous
        shapeLayer.masksToBounds = true
        shapeLayer.contentsScale = scale
        shapeLayer.render(in: context)

        context.draw(
            cgImage,
            in: CGRect(
                x: borderPixels,
                y: borderPixels,
                width: cgImage.width,
                height: cgImage.height
            )
        )

        guard let bordered = context.makeImage() else {
            throw CaptureError("Failed to generate bordered image")
        }

        let borderSizePoints = CGFloat(borderPixels) / scale
        let newSize = CGSize(
            width: image.size.width + borderSizePoints * 2,
            height: image.size.height + borderSizePoints * 2
        )

        return CaptureImage(cgImage: bordered, scale: scale, size: newSize)
    }
}
