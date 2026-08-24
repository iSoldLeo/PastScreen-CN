//
//  ImageProcessor.swift
//  Mio
//
//  The only heavy bitmap executor in module 06. The actor serializes peak
//  allocation pressure; capture/editor/onboarding retain their own operation
//  identity and Task lifetime.
//

import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import OSLog

actor ImageProcessor {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "Image.Processing"
    )

    private let frameResources: FrameResources?
    private lazy var ciContext = CIContext(options: nil)

    init(frameResources: FrameResources?) {
        self.frameResources = frameResources
    }

    func prepareImage(_ request: ImagePreparationRequest) async throws -> CaptureImage {
        let startedAt = ContinuousClock().now
        let correlationID = request.correlationID.uuidString
        var stage = "validation"
        var clipped = false

        Self.logger.info(
            "event=image_prepare_started correlation_id=\(correlationID, privacy: .public) crop_requested=\(request.crop != nil, privacy: .public) frame_requested=\(request.frame.isRequested, privacy: .public)"
        )

        do {
            try Task.checkCancellation()
            var image = try Self.revalidate(request.source)

            if let crop = request.crop {
                stage = "crop"
                let result = try Self.crop(image, instruction: crop)
                image = result.image
                clipped = result.clipped
                try Task.checkCancellation()
                Self.logger.debug(
                    "event=image_stage_completed correlation_id=\(correlationID, privacy: .public) stage=crop clipped=\(clipped, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
                )
            }

            switch request.frame {
            case .none:
                break
            case .apply(let configuration):
                stage = "frame"
                try Task.checkCancellation()
                guard let frameResources else {
                    throw ImageProcessingError.missingFrameResource(name: "FrameLogo")
                }
                image = try FrameRenderer.compose(
                    image: image,
                    configuration: configuration,
                    resources: frameResources
                )
                try Task.checkCancellation()
                Self.logger.debug(
                    "event=image_stage_completed correlation_id=\(correlationID, privacy: .public) stage=frame duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
                )
            }

            Self.logger.info(
                "event=image_prepare_succeeded correlation_id=\(correlationID, privacy: .public) clipped=\(clipped, privacy: .public) frame_applied=\(request.frame.isRequested, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
            )
            return image
        } catch is CancellationError {
            Self.logger.notice(
                "event=image_prepare_cancelled correlation_id=\(correlationID, privacy: .public) stage=\(stage, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
            )
            throw CancellationError()
        } catch let error as ImageProcessingError {
            Self.logger.error(
                "event=image_prepare_failed correlation_id=\(correlationID, privacy: .public) stage=\(stage, privacy: .public) stable_error_code=\(error.stableCode, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
            )
            throw error
        }
    }

    func makePixelatedSource(
        from source: CaptureImage,
        correlationID: UUID
    ) async throws -> CaptureImage {
        let startedAt = ContinuousClock().now
        let logID = correlationID.uuidString
        Self.logger.info(
            "event=image_mosaic_started correlation_id=\(logID, privacy: .public)"
        )

        do {
            try Task.checkCancellation()
            let source = try Self.revalidate(source)
            let input = CIImage(cgImage: source.cgImage)
            let filter = CIFilter.pixellate()
            filter.inputImage = input
            filter.scale = 16
            filter.center = CGPoint(
                x: CGFloat(source.cgImage.width) / 2,
                y: CGFloat(source.cgImage.height) / 2
            )
            guard let output = filter.outputImage?.cropped(to: input.extent),
                  let rendered = ciContext.createCGImage(output, from: input.extent),
                  rendered.width == source.cgImage.width,
                  rendered.height == source.cgImage.height
            else {
                throw ImageProcessingError.mosaicFailed
            }
            try Task.checkCancellation()
            let result = try CaptureImage(validating: rendered, scale: source.scale)
            Self.logger.info(
                "event=image_mosaic_succeeded correlation_id=\(logID, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
            )
            return result
        } catch is CancellationError {
            Self.logger.notice(
                "event=image_mosaic_cancelled correlation_id=\(logID, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
            )
            throw CancellationError()
        } catch let error as ImageProcessingError {
            Self.logger.error(
                "event=image_mosaic_failed correlation_id=\(logID, privacy: .public) stable_error_code=\(error.stableCode, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
            )
            throw error
        }
    }

    private static func revalidate(_ image: CaptureImage) throws -> CaptureImage {
        do {
            return try CaptureImage(validating: image.cgImage, scale: image.scale)
        } catch let error as CaptureImage.ValidationError {
            throw ImageProcessingError.invalidSource(error)
        }
    }

    private static func crop(
        _ source: CaptureImage,
        instruction: CropInstruction
    ) throws -> (image: CaptureImage, clipped: Bool) {
        let rect = instruction.rectInSourcePoints
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0
        else {
            throw ImageProcessingError.invalidCropGeometry
        }

        let scale = source.scale
        let fractionalPixels = CGRect(
            x: rect.minX * scale,
            y: (source.size.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        guard fractionalPixels.origin.x.isFinite,
              fractionalPixels.origin.y.isFinite,
              fractionalPixels.width.isFinite,
              fractionalPixels.height.isFinite
        else {
            throw ImageProcessingError.invalidCropGeometry
        }

        let integralPixels = fractionalPixels.integral
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: source.cgImage.width,
            height: source.cgImage.height
        )
        let clippedPixels = integralPixels.intersection(imageBounds)
        guard !clippedPixels.isNull,
              clippedPixels.width > 0,
              clippedPixels.height > 0
        else {
            throw ImageProcessingError.cropOutsideSource
        }
        guard let cropped = source.cgImage.cropping(to: clippedPixels) else {
            throw ImageProcessingError.cropFailed
        }

        return (
            try CaptureImage(validating: cropped, scale: scale),
            clippedPixels != integralPixels
        )
    }

    private static func durationMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Int64 {
        let duration = start.duration(to: ContinuousClock().now)
        let components = duration.components
        return Int64(components.seconds) * 1_000
            + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}

nonisolated private extension FrameApplication {
    var isRequested: Bool {
        switch self {
        case .none: false
        case .apply: true
        }
    }
}
