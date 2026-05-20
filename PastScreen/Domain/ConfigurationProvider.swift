//
//  ConfigurationProvider.swift
//  PastScreen
//
//  Protocol for providing capture configuration snapshots.
//  Decouples Application layer from concrete settings stores.
//

public protocol ConfigurationProvider: Sendable {
    func current() async -> CaptureConfiguration
}
