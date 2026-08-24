//
//  ImageProcessingTypes.swift
//  Mio
//
//  Sendable value boundary for module 06. These values deliberately contain
//  no AppKit objects, route names, settings objects or delivery state.
//

import Foundation
import CoreGraphics

nonisolated struct CropInstruction: Sendable {
    /// AppKit points local to the already-selected source, bottom-left origin.
    let rectInSourcePoints: CGRect
}

nonisolated enum ResolvedFrameTheme: Sendable, Equatable {
    case light
    case dark
}

nonisolated struct ResolvedFrameConfiguration: Sendable, Equatable {
    let theme: ResolvedFrameTheme
    /// Defensive boundary for historical or non-canonical preference values.
    let signature: String

    init(theme: ResolvedFrameTheme, signature: String) {
        self.theme = theme
        self.signature = String(signature.prefix(40))
    }
}

nonisolated enum FrameApplication: Sendable, Equatable {
    case none
    case apply(ResolvedFrameConfiguration)
}

nonisolated struct ImagePreparationRequest: Sendable {
    /// Created by the outer capture/editor/onboarding operation owner.
    let correlationID: UUID
    let source: CaptureImage
    let crop: CropInstruction?
    let frame: FrameApplication
}

nonisolated enum ImageProcessingError: Error, Sendable, Equatable {
    enum Stage: String, Sendable {
        case alphaProbe = "alpha_probe"
        case frameCanvas = "frame_canvas"
        case finalCopy = "final_copy"
    }

    case invalidSource(CaptureImage.ValidationError)
    case invalidCropGeometry
    case cropOutsideSource
    case cropFailed
    case mosaicFailed
    case missingFrameResource(name: String)
    case allocationFailed(stage: Stage)
    case renderFailed(stage: Stage)

    var stableCode: String {
        switch self {
        case .invalidSource: "invalid_source"
        case .invalidCropGeometry: "invalid_crop_geometry"
        case .cropOutsideSource: "crop_outside_source"
        case .cropFailed: "crop_failed"
        case .mosaicFailed: "mosaic_failed"
        case .missingFrameResource: "missing_frame_resource"
        case .allocationFailed(let stage): "allocation_failed_\(stage.rawValue)"
        case .renderFailed(let stage): "render_failed_\(stage.rawValue)"
        }
    }
}
