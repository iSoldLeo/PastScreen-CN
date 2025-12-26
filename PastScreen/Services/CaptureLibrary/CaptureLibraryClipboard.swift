//
//  CaptureLibraryClipboard.swift
//  PastScreen
//

import AppKit
import Foundation

extension CaptureLibrary {
    @MainActor
    func copyImageToClipboard(item: CaptureItem) {
        guard let result = bestImageURL(for: item, allowThumbnailFallback: true) else {
            DynamicIslandManager.shared.show(message: "无可复制图片", duration: 2.0, style: .failure)
            return
        }

        let url = result.url
        guard let image = NSImage(contentsOfFile: url.path) else {
            DynamicIslandManager.shared.show(message: "读取图片失败", duration: 2.0, style: .failure)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setString(url.path, forType: .string)

        if AppSettings.shared.playSoundOnCapture {
            NSSound(named: "Pop")?.play()
        }

        if result.isThumbnail {
            DynamicIslandManager.shared.show(message: "已复制（缩略图）", duration: 1.6)
        } else {
            DynamicIslandManager.shared.show(message: "已复制", duration: 1.5)
        }
    }

    @MainActor
    func copyPathToClipboard(item: CaptureItem) {
        guard let url = bestAnyURL(for: item) else {
            DynamicIslandManager.shared.show(message: "无可复制路径", duration: 2.0, style: .failure)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
        DynamicIslandManager.shared.show(message: "路径已复制", duration: 1.5)
    }

    @MainActor
    func revealInFinder(item: CaptureItem) {
        guard let url = bestAnyURL(for: item) else {
            DynamicIslandManager.shared.show(message: "找不到文件", duration: 2.0, style: .failure)
            return
        }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    private func bestImageURL(for item: CaptureItem, allowThumbnailFallback: Bool) -> (url: URL, isThumbnail: Bool)? {
        if let url = bestAnyURL(for: item, requireCopyableImage: true) {
            return (url: url, isThumbnail: false)
        }
        guard allowThumbnailFallback else { return nil }
        guard let url = resolveInternalURL(item.internalThumbPath) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url: url, isThumbnail: true)
    }

    private func bestAnyURL(for item: CaptureItem, requireCopyableImage: Bool = false) -> URL? {
        let candidates: [URL] = [
            resolveInternalURL(item.internalOriginalPath),
            resolveInternalURL(item.internalPreviewPath),
            item.externalFileURL,
            requireCopyableImage ? nil : resolveInternalURL(item.internalThumbPath)
        ].compactMap { $0 }

        let fileManager = FileManager.default
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private func resolveInternalURL(_ relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        guard let root = try? CaptureLibraryFileStore.defaultRootURL() else { return nil }
        return root.appendingPathComponent(relativePath, isDirectory: false)
    }
}

