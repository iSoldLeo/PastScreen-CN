//
//  CaptureItemCaptureType.swift
//  Mio
//
//  Domain-layer capture type enum.
//

nonisolated public enum CaptureItemCaptureType: Int, Codable, CaseIterable, Sendable {
    case area = 0
    case window = 1
    case fullscreen = 2
}
