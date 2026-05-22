//
//  ImageRendering.swift
//  Mio
//
//  Domain protocol for image post-processing (borders, cropping, etc.)
//

import Foundation

public protocol ImageRendering: Sendable {
    func addBorder(to image: CaptureImage, config: CaptureConfiguration) async throws -> CaptureImage
}
