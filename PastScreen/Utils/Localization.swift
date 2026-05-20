//
//  Localization.swift
//  PastScreen
//
//  Runtime language switching without app restart.
//

import Foundation

// Keep a reference to the currently selected bundle.
// nonisolated(unsafe): This variable is set once during app initialization via setAppLanguage()
// and then only read by localizedString(). The write-once-then-read pattern is safe.
nonisolated(unsafe) private var activeLanguageBundle: Bundle?

// SAFETY: SwizzledBundle inherits from Bundle (an immutable, thread-safe Foundation class).
// The only override reads `activeLanguageBundle` which is set once during initialization.
// Bundle's own methods are documented as thread-safe.
private class SwizzledBundle: Bundle, @unchecked Sendable {
    nonisolated override init?(path: String) {
        super.init(path: path)
    }

    nonisolated override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = activeLanguageBundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// Switch localization bundle at runtime. Pass nil to use system.
    /// nonisolated: only touches the write-once activeLanguageBundle variable.
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
            activeLanguageBundle = nil
            return
        }

        activeLanguageBundle = bundle
    }
}
