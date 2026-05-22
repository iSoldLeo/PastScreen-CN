//
//  WindowCaptureError.swift
//  Mio
//
//  Domain-layer error for window capture failures.
//  SCStreamError is digested to String before crossing boundaries.
//

import Foundation
import CoreGraphics

public enum WindowCaptureError: LocalizedError, Sendable {
    case mouseLocationUnavailable
    case noWindowAtPoint
    case shareableWindowNotFound(CGWindowID)
    case invalidWindowSize
    case streamError(description: String)
    case generic(String)

    public var errorDescription: String? {
        switch self {
        case .mouseLocationUnavailable:
            return NSLocalizedString("无法获取鼠标位置", comment: "")
        case .noWindowAtPoint:
            return NSLocalizedString("找不到命中的窗口", comment: "")
        case .shareableWindowNotFound(let id):
            return String(format: NSLocalizedString("未在 ScreenCaptureKit 集合中找到窗口（ID: %u）", comment: ""), id)
        case .invalidWindowSize:
            return NSLocalizedString("窗口尺寸无效，无法截图", comment: "")
        case .streamError(let description):
            return description
        case .generic(let message):
            return message
        }
    }
}
