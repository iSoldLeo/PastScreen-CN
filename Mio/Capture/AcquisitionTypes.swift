//
//  AcquisitionTypes.swift
//  Mio
//
//  Immutable values shared by the acquisition, session and selection layers.
//  Every CGRect name states its coordinate space; no platform object crosses
//  this boundary.
//


import CoreGraphics
import Foundation

/// The single immutable image value shared by capture, processing, editor and
/// delivery. The macOS 27 SDK declares `CGImage` Sendable, so this conformance
/// remains compiler checked.
nonisolated public struct CaptureImage: Sendable {
    public enum ValidationError: Error, Sendable, Equatable {
        case nonFiniteScale
        case nonPositiveScale
    }

    public let cgImage: CGImage
    public let scale: CGFloat

    public var size: CGSize {
        CGSize(
            width: CGFloat(cgImage.width) / scale,
            height: CGFloat(cgImage.height) / scale
        )
    }

    public init(validating cgImage: CGImage, scale: CGFloat) throws {
        guard scale.isFinite else { throw ValidationError.nonFiniteScale }
        guard scale > 0 else { throw ValidationError.nonPositiveScale }
        self.cgImage = cgImage
        self.scale = scale
    }
}

nonisolated struct FrozenScreen: Sendable {
    let displayID: CGDirectDisplayID
    let frameInAppKitPoints: CGRect
    let image: CaptureImage
}

nonisolated struct FrozenScreens: Sendable {
    let ordered: [FrozenScreen]
}

nonisolated struct CaptureWindowDescriptor: Sendable, Equatable {
    let windowID: CGWindowID
    let frameInAppKitPoints: CGRect
    let primaryDisplayID: CGDirectDisplayID
    let ownerPID: pid_t
    let layer: Int
    let frontToBackIndex: Int
    let isSelectable: Bool
}

nonisolated enum PrewarmOutcome: Sendable, Equatable {
    case completed
    case skippedForActiveCapture
}

nonisolated enum CaptureAcquisitionError: Error, Sendable, Equatable {
    case pipelineBusy
    case noDisplays
    case topologyChanged
    case permissionDenied
    case contentEnumerationFailed
    case displayUnavailable(CGDirectDisplayID)
    case captureInterrupted
    case invalidGeometry
    case invalidPixelDimensions
    case windowUnavailable(CGWindowID)
    case platformFailure(code: Int?)

    var stableLogCode: String {
        switch self {
        case .pipelineBusy: "pipeline_busy"
        case .noDisplays: "no_displays"
        case .topologyChanged: "topology_changed"
        case .permissionDenied: "permission_denied"
        case .contentEnumerationFailed: "content_enumeration_failed"
        case .displayUnavailable: "display_unavailable"
        case .captureInterrupted: "capture_interrupted"
        case .invalidGeometry: "invalid_geometry"
        case .invalidPixelDimensions: "invalid_pixel_dimensions"
        case .windowUnavailable: "window_unavailable"
        case .platformFailure: "platform_failure"
        }
    }
}
