//
//  DynamicIslandView.swift
//  PastScreen
//
//  Lightweight menu bar confirmation pill
//

import AppKit

/// Manager for temporary "✓ Saved" indicator in the menu bar
@MainActor
class DynamicIslandManager {
    static let shared = DynamicIslandManager()
    private var pillStatusItem: NSStatusItem?
    private var dismissTask: Task<Void, Never>?

    enum Style: Sendable {
        case success
        case failure
    }

    func show(message: String, duration: TimeInterval = 3.0, style: Style = .success) {
        dismiss()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        pillStatusItem = statusItem
        switch style {
        case .success:
            button.title = "✓ \(message)"
            button.contentTintColor = .systemGreen
        case .failure:
            button.title = "✕ \(message)"
            button.contentTintColor = .systemRed
        }
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.isBordered = true
        button.bezelStyle = .rounded
        button.focusRingType = .none

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil

        guard let item = pillStatusItem else { return }

        // Clear reference BEFORE starting animation to prevent race conditions
        pillStatusItem = nil

        // Remove immediately without animation to prevent statusItem accumulation
        NSStatusBar.system.removeStatusItem(item)
    }
}
