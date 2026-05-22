//
//  EdgeInsetValues.swift
//  Mio
//
//  Sendable replacement for NSEdgeInsets, used for padding values
//  that cross actor boundaries.
//

import Foundation

public struct EdgeInsetValues: Sendable {
    public let top: CGFloat
    public let left: CGFloat
    public let bottom: CGFloat
    public let right: CGFloat

    public static let zero = EdgeInsetValues(top: 0, left: 0, bottom: 0, right: 0)

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init(_ insets: NSEdgeInsets) {
        self.top = insets.top
        self.left = insets.left
        self.bottom = insets.bottom
        self.right = insets.right
    }
}
