//
//  CaptureLibrarySemanticSearchService.swift
//  PastScreen
//

import CryptoKit
import Foundation
import NaturalLanguage

// MARK: - Semantic Search (M3, Experimental)

actor CaptureLibrarySemanticSearchService {
    static let shared = CaptureLibrarySemanticSearchService()

    private struct Config {
        var embedding: NLEmbedding
        var modelName: String
        var dim: Int
        var isSentence: Bool
        var language: NLLanguage
    }

    private var cachedConfigs: [String: Config] = [:]

    func rerank(items: [CaptureItem], queryText: String, includeFTSWeight: Bool = true) async -> [CaptureItem] {
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, items.count > 1 else { return items }

        guard let config = resolveConfig(for: trimmedQuery) else { return items }
        guard let queryVector = embed(text: trimmedQuery, config: config) else { return items }

        var scored: [(item: CaptureItem, index: Int, finalScore: Double)] = []
        scored.reserveCapacity(items.count)

        var updates: [(id: UUID, embedding: Data, sourceHash: String)] = []

        let n = max(1, items.count - 1)
        for (index, item) in items.enumerated() {
            let ftsScore: Double = includeFTSWeight ? (1.0 - (Double(index) / Double(n))) : 0.0
            let semanticText = Self.semanticText(for: item)
            let sourceHash = Self.sha256Hex(semanticText)

            let itemVector: [Float]?
            if let existing = item.embedding,
               item.embeddingModel == config.modelName,
               item.embeddingDim == config.dim,
               item.embeddingSourceHash == sourceHash,
               let decoded = Self.decodeEmbedding(existing, dim: config.dim) {
                itemVector = decoded
            } else {
                itemVector = embed(text: semanticText, config: config)
                if let itemVector {
                    updates.append((id: item.id, embedding: Self.encodeEmbedding(itemVector), sourceHash: sourceHash))
                }
            }

            let semanticScore: Double
            if let itemVector {
                let cosine = Double(Self.dot(queryVector, itemVector))
                let normalized = min(1.0, max(0.0, (cosine + 1.0) / 2.0))
                semanticScore = normalized
            } else {
                semanticScore = 0
            }

            let finalScore: Double
            if includeFTSWeight {
                finalScore = 0.6 * ftsScore + 0.4 * semanticScore
            } else {
                finalScore = semanticScore
            }
            scored.append((item: item, index: index, finalScore: finalScore))
        }

        let reranked = scored.sorted { lhs, rhs in
            if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
            if lhs.item.createdAt != rhs.item.createdAt { return lhs.item.createdAt > rhs.item.createdAt }
            return lhs.index < rhs.index
        }.map { $0.item }

        scheduleEmbeddingWrites(updates: updates, config: config)
        return reranked
    }

    private func resolveConfig(for query: String) -> Config? {
        let candidates = Self.preferredLanguages(for: query)

        for lang in candidates {
            let cacheKey = "sentence:\(lang.rawValue)"
            if let cached = cachedConfigs[cacheKey] {
                return cached
            }
            if let embedding = NLEmbedding.sentenceEmbedding(for: lang) {
                let config = Config(
                    embedding: embedding,
                    modelName: "nl_sentence_\(lang.rawValue)",
                    dim: embedding.dimension,
                    isSentence: true,
                    language: lang
                )
                cachedConfigs[cacheKey] = config
                return config
            }
        }

        for lang in candidates {
            let cacheKey = "word:\(lang.rawValue)"
            if let cached = cachedConfigs[cacheKey] {
                return cached
            }
            if let embedding = NLEmbedding.wordEmbedding(for: lang) {
                let config = Config(
                    embedding: embedding,
                    modelName: "nl_word_\(lang.rawValue)",
                    dim: embedding.dimension,
                    isSentence: false,
                    language: lang
                )
                cachedConfigs[cacheKey] = config
                return config
            }
        }

        return nil
    }

    private func embed(text: String, config: Config) -> [Float]? {
        if config.isSentence {
            guard let vec = config.embedding.vector(for: text) else { return nil }
            guard vec.count == config.dim else { return nil }
            let floats = vec.map { Float($0) }
            return Self.normalized(floats)
        }

        let tokens = Self.tokenize(text: text, maxTokens: 256)
        guard !tokens.isEmpty else { return nil }

        var sum = [Double](repeating: 0, count: config.dim)
        var count = 0

        for token in tokens {
            guard let vec = config.embedding.vector(for: token), vec.count == config.dim else { continue }
            for i in 0..<config.dim {
                sum[i] += vec[i]
            }
            count += 1
        }

        guard count > 0 else { return nil }

        var out = [Float](repeating: 0, count: config.dim)
        let inv = 1.0 / Double(count)
        for i in 0..<config.dim {
            out[i] = Float(sum[i] * inv)
        }

        return Self.normalized(out)
    }

    private func scheduleEmbeddingWrites(updates: [(id: UUID, embedding: Data, sourceHash: String)], config: Config) {
        guard !updates.isEmpty else { return }
        let limited = Array(updates.prefix(40))
        Task.detached(priority: .background) {
            for update in limited {
                await CaptureLibrary.shared.updateEmbedding(
                    for: update.id,
                    model: config.modelName,
                    dim: config.dim,
                    embedding: update.embedding,
                    sourceHash: update.sourceHash
                )
            }
        }
    }

    private static func preferredLanguages(for text: String) -> [NLLanguage] {
        var candidates: [NLLanguage] = []

        if let dominant = NLLanguageRecognizer.dominantLanguage(for: text) {
            candidates.append(dominant)
        }

        for identifier in Locale.preferredLanguages {
            let base = identifier.split(separator: "-").first.map(String.init) ?? identifier
            candidates.append(NLLanguage(rawValue: base))
        }

        candidates.append(.simplifiedChinese)
        candidates.append(.traditionalChinese)
        candidates.append(.english)

        var unique: [NLLanguage] = []
        var seen = Set<NLLanguage>()
        for language in candidates where seen.insert(language).inserted {
            unique.append(language)
        }
        return unique
    }

    private static func tokenize(text: String, maxTokens: Int) -> [String] {
        let lowered = text.lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = lowered

        var out: [String] = []
        out.reserveCapacity(min(64, maxTokens))

        tokenizer.enumerateTokens(in: lowered.startIndex..<lowered.endIndex) { range, _ in
            if out.count >= maxTokens { return false }
            let token = String(lowered[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return true }
            guard token.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }) else {
                return true
            }
            out.append(token)
            return true
        }

        return out
    }

    private static func semanticText(for item: CaptureItem) -> String {
        var parts: [String] = []
        if let appName = item.appName, !appName.isEmpty { parts.append(appName) }
        if !item.tagsCache.isEmpty { parts.append(item.tagsCache) }
        if let note = item.note, !note.isEmpty { parts.append(note) }
        if let external = item.externalFilePath, !external.isEmpty {
            parts.append(URL(fileURLWithPath: external).lastPathComponent)
        }
        if let ocr = item.ocrText, !ocr.isEmpty {
            parts.append(String(ocr.prefix(2_000)))
        }
        return parts.joined(separator: " ")
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeEmbedding(_ vector: [Float]) -> Data {
        var copy = vector
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    private static func decodeEmbedding(_ data: Data, dim: Int) -> [Float]? {
        let expected = dim * MemoryLayout<Float>.size
        guard data.count == expected else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        var sum: Float = 0
        for i in 0..<count {
            sum += a[i] * b[i]
        }
        return sum
    }

    private static func normalized(_ v: [Float]) -> [Float]? {
        var sum: Double = 0
        for x in v {
            sum += Double(x * x)
        }
        let norm = sqrt(sum)
        guard norm > 0 else { return nil }
        let inv = Float(1.0 / norm)
        return v.map { $0 * inv }
    }
}

