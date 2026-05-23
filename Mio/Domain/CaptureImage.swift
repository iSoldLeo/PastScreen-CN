//
//  CaptureImage.swift
//  Mio
//
//  Single Sendable image DTO used across actor boundaries (capture
//  pipeline, file/clipboard output, window capture results).
//
//  Three independent claims justify `@unchecked Sendable`:
//    1. CGImage is an immutable Core Foundation reference type — pixel
//       data cannot be modified after creation. Apple has not yet
//       declared CGImage Sendable, but the immutability contract is
//       documented in the Core Graphics reference.
//    2. All stored properties are `let`; the struct itself is value-
//       immutable, so Sendability cannot be broken by a future
//       mutation. **Adding a `var` field to this struct is a SAFETY
//       violation and must be reviewed.**
//    3. Cross-actor access is read-only. `CaptureImage` exposes no
//       mutating API; downstream consumers (FileOutputService,
//       ClipboardOutputService) only read the fields and pass the
//       value by copy.
//
//  The struct also carries `scale` (backing scale factor of the source
//  display) and `size` (point size of the image). Both are needed by
//  downstream consumers:
//    - FileOutputService stamps `NSBitmapImageRep.size` with the point
//      size so PNG/JPEG metadata reports the correct on-disk dimensions.
//    - ClipboardOutputService stamps the same point size on the
//      pasteboard `NSImage`.
//
//  TODO: Remove `@unchecked` once Apple marks CGImage as Sendable.
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
