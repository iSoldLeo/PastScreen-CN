//
//  DynamicIslandView.swift
//  PastScreen
//
//  Lightweight menu bar confirmation pill
//

import AppKit

/// Manager for temporary "✓ Saved" indicator in the menu bar
class DynamicIslandManager {
    static let shared = DynamicIslandManager()
    private var pillStatusItem: NSStatusItem?
    private var dismissTimer: Timer?

    enum Style {
        case success
        case failure
    }

    func show(message: String, duration: TimeInterval = 3.0, style: Style = .success) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.dismiss()

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

            dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let item = pillStatusItem else { return }

        // Clear reference BEFORE starting animation to prevent race conditions
        pillStatusItem = nil

        // Remove immediately without animation to prevent statusItem accumulation
        NSStatusBar.system.removeStatusItem(item)
    }
}
