//
//  SendableCGImage.swift
//  PastScreen
//
//  Sendable wrapper for CGImage.
//  CGImage is an immutable Core Foundation reference type;
//  pixel data cannot be modified after creation, so cross-actor reads are safe.
//

import CoreGraphics

public struct SendableCGImage: @unchecked Sendable {
    public let image: CGImage

    public init(_ image: CGImage) {
        self.image = image
    }
}
