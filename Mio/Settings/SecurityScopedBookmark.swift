//
//  SecurityScopedBookmark.swift
//  Mio
//
//  Nonisolated Foundation boundary for synchronous bookmark creation,
//  resolution and stale refresh. It owns no state, task, URL lease or policy.
//

import Foundation

nonisolated struct PreparedSaveFolderBookmark: Sendable {
    let url: URL
    let refreshedData: Data?
    let displayName: String
}

nonisolated enum SecurityScopedBookmark {
    @concurrent
    static func resolve(_ bookmarkData: Data) async throws -> PreparedSaveFolderBookmark {
        try Task.checkCancellation()
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SaveFolderFailure.invalidBookmark
        }

        let refreshedData: Data?
        if isStale {
            do {
                refreshedData = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                throw SaveFolderFailure.staleRefreshFailed
            }
        } else {
            refreshedData = nil
        }
        try Task.checkCancellation()
        return PreparedSaveFolderBookmark(
            url: url,
            refreshedData: refreshedData,
            displayName: displayName(for: url)
        )
    }

    @concurrent
    static func create(from selectedURL: URL) async throws -> PreparedSaveFolderBookmark {
        try Task.checkCancellation()
        let bookmarkData: Data
        do {
            bookmarkData = try selectedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw SaveFolderFailure.unavailable
        }
        let prepared = try await resolve(bookmarkData)
        return PreparedSaveFolderBookmark(
            url: prepared.url,
            refreshedData: prepared.refreshedData ?? bookmarkData,
            displayName: prepared.displayName
        )
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? "/" : name
    }
}
