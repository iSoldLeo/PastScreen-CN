//
//  ShortcutStore.swift
//  Mio
//
//  The only persistence owner for the desired shortcut snapshot.
//

import Combine
import Foundation
import OSLog

@MainActor
final class ShortcutStore: ObservableObject {
    private static let canonicalKey = "shortcutAssignments"
    private static let schemaVersion: UInt8 = 1
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "Hotkeys.Store"
    )

    @Published private(set) var assignments: ShortcutAssignments
    let loadDisposition: ShortcutStoreLoadDisposition

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults

        let result = Self.load(from: defaults)
        self.assignments = result.assignments
        self.loadDisposition = result.disposition

        Self.logger.info(
            "event=shortcut.store.load result=\(Self.logValue(result.disposition), privacy: .public)"
        )
    }

    func commit(
        _ candidate: ShortcutAssignments
    ) -> Result<Void, ShortcutStoreCommitFailure> {
        if let failure = ShortcutValidator.validateSnapshot(candidate) {
            Self.logger.error(
                "event=shortcut.store.commit result=semantic_invalid failure=\(Self.logValue(failure), privacy: .public)"
            )
            return .failure(.semanticInvalid(failure))
        }

        let payload = ShortcutStorePayload(
            schemaVersion: Self.schemaVersion,
            assignments: candidate
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            Self.logger.error(
                "event=shortcut.store.commit result=encoding_failed error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            return .failure(.persistence(.encodingFailed))
        }

        defaults.set(data, forKey: Self.canonicalKey)
        assignments = candidate
        Self.logger.info("event=shortcut.store.commit result=accepted_by_defaults_api")
        return .success(())
    }

    private static func load(
        from defaults: UserDefaults
    ) -> (assignments: ShortcutAssignments, disposition: ShortcutStoreLoadDisposition) {
        let productDefaults = ShortcutAssignments.productDefaults
        precondition(
            ShortcutValidator.validateSnapshot(productDefaults) == nil,
            "Product shortcut defaults must satisfy the shortcut policy."
        )

        guard let data = defaults.data(forKey: canonicalKey) else {
            return (productDefaults, .missingDefaulted)
        }

        let payload: ShortcutStorePayload
        do {
            payload = try JSONDecoder().decode(ShortcutStorePayload.self, from: data)
        } catch {
            return (productDefaults, .decodeFailedDefaulted)
        }

        guard payload.schemaVersion == schemaVersion else {
            return (productDefaults, .unsupportedVersionDefaulted)
        }

        if let failure = ShortcutValidator.validateSnapshot(payload.assignments) {
            return (productDefaults, .semanticInvalidDefaulted(failure))
        }

        return (payload.assignments, .loaded)
    }

    private static func logValue(_ disposition: ShortcutStoreLoadDisposition) -> String {
        switch disposition {
        case .loaded: "loaded"
        case .missingDefaulted: "missing_defaulted"
        case .decodeFailedDefaulted: "decode_failed_defaulted"
        case .unsupportedVersionDefaulted: "unsupported_version_defaulted"
        case let .semanticInvalidDefaulted(failure):
            "semantic_invalid_defaulted:\(logValue(failure))"
        }
    }

    private static func logValue(_ failure: ShortcutSemanticFailure) -> String {
        switch failure {
        case let .unsupportedModifierBits(action):
            "unsupported_modifier_bits:\(action.rawValue)"
        case let .primaryModifierRequired(action):
            "primary_modifier_required:\(action.rawValue)"
        case let .duplicateAssignments(first, second):
            "duplicate_assignments:\(first.rawValue):\(second.rawValue)"
        }
    }
}
