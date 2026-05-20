//
//  CaptureImage.swift
//  PastScreen
//
//  Domain-layer image holder. CGImage is not marked Sendable by Apple,
//  but it is an immutable Core Foundation reference type — pixel data
//  cannot be modified after creation. Cross-actor read-only access is safe.
//
//  TODO: Remove @unchecked once Apple marks CGImage as Sendable.
//

import Foundation
import CoreGraphics

public struct CaptureImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let scale: CGFloat
    public let size: CGSize

    nonisolated public init(cgImage: CGImage, scale: CGFloat, size: CGSize) {
        self.cgImage = cgImage
        self.scale = scale
        self.size = size
    }
}
