//
//  WindowCaptureInfo.swift
//  PastScreen
//
//  Sendable DTO that flattens SCWindow/SCRunningApplication into plain-value fields.
//

import CoreGraphics

public struct WindowCaptureInfo: Sendable {
    public let image: SendableCGImage
    public let windowFrame: CGRect
    public let appBundleID: String?
    public let appName: String?
    public let paddingPoints: EdgeInsetValues

    public init(
        image: SendableCGImage,
        windowFrame: CGRect,
        appBundleID: String?,
        appName: String?,
        paddingPoints: EdgeInsetValues
    ) {
        self.image = image
        self.windowFrame = windowFrame
        self.appBundleID = appBundleID
        self.appName = appName
        self.paddingPoints = paddingPoints
    }
}
