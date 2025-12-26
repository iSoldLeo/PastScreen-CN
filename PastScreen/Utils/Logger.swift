//
//  Logger.swift
//  PastScreen
//
//  Conditional logging system - prints only in DEBUG builds
//

import Foundation
import os.log

struct Logger {
    enum LogLevel: String {
        case debug = "🔍"
        case info = "ℹ️"
        case success = "✅"
        case warning = "⚠️"
        case error = "❌"
    }

    nonisolated static func log(_ message: String, level: LogLevel = .info, category: String = "APP") {
        #if DEBUG
        let emoji = level.rawValue
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print("\(timestamp) \(emoji) [\(category)] \(message)")
        #endif
    }

    nonisolated static func debug(_ message: String, category: String = "APP") {
        log(message, level: .debug, category: category)
    }

    nonisolated static func info(_ message: String, category: String = "APP") {
        log(message, level: .info, category: category)
    }

    nonisolated static func success(_ message: String, category: String = "APP") {
        log(message, level: .success, category: category)
    }

    nonisolated static func warning(_ message: String, category: String = "APP") {
        log(message, level: .warning, category: category)
    }

    nonisolated static func error(_ message: String, category: String = "APP") {
        log(message, level: .error, category: category)
    }
}

// Convenience aliases for shorter syntax
nonisolated func logDebug(_ message: String, category: String = "APP") {
    Logger.debug(message, category: category)
}

nonisolated func logInfo(_ message: String, category: String = "APP") {
    Logger.info(message, category: category)
}

nonisolated func logSuccess(_ message: String, category: String = "APP") {
    Logger.success(message, category: category)
}

nonisolated func logWarning(_ message: String, category: String = "APP") {
    Logger.warning(message, category: category)
}

nonisolated func logError(_ message: String, category: String = "APP") {
    Logger.error(message, category: category)
}
