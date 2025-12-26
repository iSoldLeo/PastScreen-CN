//
//  CaptureLibraryFTS.swift
//  PastScreen
//

import Foundation

enum CaptureLibraryFTS {
    nonisolated static func makeText(
        appName: String?,
        externalFilePath: String?,
        tagsCache: String,
        note: String?,
        ocrText: String?
    ) -> String {
        var parts: [String] = []
        if let appName, !appName.isEmpty { parts.append(appName) }
        if !tagsCache.isEmpty { parts.append(tagsCache) }
        if let note, !note.isEmpty { parts.append(note) }
        if let ocrText, !ocrText.isEmpty { parts.append(ocrText) }
        if let externalFilePath, !externalFilePath.isEmpty {
            parts.append(URL(fileURLWithPath: externalFilePath).lastPathComponent)
        }
        return parts.joined(separator: "\n")
    }

    nonisolated static func makeMatchQuery(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let terms: [String] = tokens.compactMap { raw in
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }

            if term.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil {
                return term + "*"
            }

            if term.range(of: #"^[\p{L}\p{Nd}]+$"#, options: .regularExpression) != nil {
                return term + "*"
            }

            let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        return terms.joined(separator: " AND ")
    }
}

enum CaptureLibraryTagNormalizer {
    nonisolated static func normalize(_ tags: [String]) -> [String] {
        let trimmed = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var unique: [String] = []
        var seen = Set<String>()
        for tag in trimmed where seen.insert(tag).inserted {
            unique.append(tag)
        }
        return Array(unique.prefix(20))
    }
}
