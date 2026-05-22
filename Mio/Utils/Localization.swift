//
//  Localization.swift
//  Mio
//
//  Runtime language switching without app restart.
//

import Foundation
import OSLog

// Thread-safe storage for the currently selected language bundle.
// Updated each time setAppLanguage() is called; only ever read by the
// SwizzledBundle override below. The lock guarantees safe concurrent reads.
private nonisolated let activeLanguageBundleLock = OSAllocatedUnfairLock<Bundle?>(initialState: nil)

// SAFETY: SwizzledBundle is process-wide isa-swizzled onto Bundle.main via
// object_setClass(). Concurrency safety relies on three guarantees:
//   1. Bundle (the parent) is documented thread-safe by Apple for read-only
//      lookups (https://developer.apple.com/documentation/foundation/bundle).
//      We never mutate Bundle's own state, so the parent's contract is upheld.
//   2. The only override (`localizedString(forKey:value:table:)`) reads a
//      Bundle? through OSAllocatedUnfairLock and then either delegates to
//      `bundle.localizedString(...)` or to `super.localizedString(...)`.
//      Both calls are read-only on Bundle and therefore safe.
//   3. SwizzledBundle stores no instance state of its own (no stored properties).
// Because Bundle is not declared Sendable by Apple but is documented
// thread-safe, `@unchecked Sendable` is the correct conformance here. The
// risk surface is bounded by Bundle's stable thread-safety contract.
private class SwizzledBundle: Bundle, @unchecked Sendable {
    nonisolated override init?(path: String) {
        super.init(path: path)
    }

    nonisolated override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        let bundle = activeLanguageBundleLock.withLock { $0 }
        if let bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// Switch localization bundle at runtime. Pass nil to revert to system.
    /// nonisolated: only touches the lock-protected activeLanguageBundle.
    ///
    /// The isa-swizzle on Bundle.main is installed once on first call (guarded
    /// by `SwizzleToken.once`); subsequent calls only update the active bundle.
    /// Once installed the swizzle persists for the entire process lifetime.
    nonisolated static func setAppLanguage(_ code: String?) {
        // One-time swizzle using a local static to avoid global isolation issues.
        struct SwizzleToken {
            static let once: Void = {
                object_setClass(Bundle.main, SwizzledBundle.self)
            }()
        }
        _ = SwizzleToken.once

        guard
            let code,
            let path = Bundle.main.path(forResource: code, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            activeLanguageBundleLock.withLock { $0 = nil }
            return
        }

        activeLanguageBundleLock.withLock { $0 = bundle }
    }
}
