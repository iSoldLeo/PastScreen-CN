//
//  CaptureEvent.swift
//  PastScreen
//
//  Type-safe events emitted during the capture pipeline.
//  Replaces string-based NotificationCenter.
//

nonisolated public enum CaptureEvent: Sendable {
    case started(CaptureConfiguration)
    case selectingRegion
    case captured(CaptureResult)
    case failed(CaptureError)
    case cancelled
    case savedToFile(path: String)
    case copiedToClipboard
}

nonisolated public struct CaptureResult: Sendable {
    public let image: CaptureImage
    public let captureType: CaptureItemCaptureType
    public let appBundleID: String?
    public let appName: String?

    public init(image: CaptureImage, captureType: CaptureItemCaptureType, appBundleID: String? = nil, appName: String? = nil) {
        self.image = image
        self.captureType = captureType
        self.appBundleID = appBundleID
        self.appName = appName
    }
}
