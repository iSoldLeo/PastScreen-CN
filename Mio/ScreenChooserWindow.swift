//
//  ScreenChooserWindow.swift
//  Mio
//
//  多屏全屏截图的屏幕选择 UI。每屏一个 OverlayPanel 显示该屏冻结图作底图，
//  鼠标点击触发选屏，鼠标所在屏 panel 边框高亮。ESC / 右键取消。
//
//  路径 B 多屏分支专用。单屏环境不创建本类型的实例。
//

import Foundation
import AppKit

@MainActor
protocol ScreenChooserWindowDelegate: AnyObject {
    func screenChooser(_ window: ScreenChooserWindow, didSelectScreen displayID: CGDirectDisplayID)
    func screenChooserDidCancel(_ window: ScreenChooserWindow)
}

// MARK: - Overlay panel (one per screen)

@MainActor
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: backing,
            defer: flag
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - ScreenChooserWindow

@MainActor
class ScreenChooserWindow: NSWindow {
    weak var chooserDelegate: ScreenChooserWindowDelegate?

    private var panels: [OverlayPanel] = []
    private var escapeKeyMonitor: Any?

    /// `true` once at least one OverlayPanel has been constructed for the
    /// current frozen-screens dictionary. The coordinator must check this
    /// before calling `show()` — if it's `false` (every screen failed the
    /// `setupPanels` consistency guard, e.g. due to a hot-plug between the
    /// freeze instant and panel construction) showing would present no UI
    /// and lock the flow.
    var hasPanels: Bool { !panels.isEmpty }

    init(
        frozenScreens: [CGDirectDisplayID: CaptureImage],
        screenFrames: [CGDirectDisplayID: CGRect]
    ) {
        // NSWindow super-init formality. The visible UI lives in `panels`,
        // mirroring SelectionWindow's role-of-a-shell pattern.
        let mainScreen = NSScreen.main ?? NSScreen.screens.first!

        super.init(
            contentRect: mainScreen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        setupPanels(frozenScreens: frozenScreens, screenFrames: screenFrames)
    }

    private func setupPanels(
        frozenScreens: [CGDirectDisplayID: CaptureImage],
        screenFrames: [CGDirectDisplayID: CGRect]
    ) {
        for screen in NSScreen.screens {
            // Skip any NSScreen for which the upstream freeze did not produce
            // a snapshot or for which the coordinator did not capture a frame.
            // This is a defensive guard for hot-plug edge cases between the
            // freeze instant and panel construction; in normal operation
            // every screen has both entries.
            guard
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                let snapshot = frozenScreens[displayID],
                let frame = screenFrames[displayID]
            else { continue }

            let panel = OverlayPanel(contentRect: frame, backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver
            panel.ignoresMouseEvents = false
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = false   // only enter/exit needed
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.setFrame(frame, display: false)

            let viewFrame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
            let overlayView = ScreenChooserOverlayView(
                frame: viewFrame,
                displayID: displayID,
                backgroundImage: snapshot
            )
            overlayView.onSelect = { [weak self] id in
                guard let self else { return }
                self.chooserDelegate?.screenChooser(self, didSelectScreen: id)
            }
            overlayView.onCancel = { [weak self] in
                guard let self else { return }
                self.chooserDelegate?.screenChooserDidCancel(self)
            }

            panel.contentView = overlayView
            panels.append(panel)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show() {
        if escapeKeyMonitor == nil {
            escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return } // ESC
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.chooserDelegate?.screenChooserDidCancel(self)
                }
            }
        }

        // Show without activating the app — preserves PRODUCT.md §5 "do not
        // steal focus before the overlay is visible". Mirrors SelectionWindow.
        for panel in panels {
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
        for panel in panels {
            panel.orderOut(nil)
            panel.ignoresMouseEvents = true
        }
    }
}

// MARK: - ScreenChooserOverlayView

@MainActor
class ScreenChooserOverlayView: NSView {
    var onSelect: ((CGDirectDisplayID) -> Void)?
    var onCancel: (() -> Void)?

    private let displayID: CGDirectDisplayID
    private let backgroundImage: CaptureImage
    private var isHovered: Bool = false
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, displayID: CGDirectDisplayID, backgroundImage: CaptureImage) {
        self.displayID = displayID
        self.backgroundImage = backgroundImage
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
        isHovered = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // Use .mouseEnteredAndExited (not .mouseMoved like SelectionOverlayView)
        // — for screen selection we only care when the cursor enters or
        // leaves the panel, not continuous movement.
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // CRITICAL: Accept first mouse click even when app is not active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // @MainActor view receiving a main-thread mouse event — the callback
        // can run synchronously. Re-entry is handled by the coordinator's
        // generation gate, not by deferring this call.
        onSelect?(displayID)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Step 1: paint the per-screen frozen snapshot as the background.
        if let context = NSGraphicsContext.current?.cgContext {
            context.draw(backgroundImage.cgImage, in: bounds)
        }

        // Step 2: dim layer to communicate the user is currently in a
        // chooser overlay (not just looking at a still frame).
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        // Step 3: thick blue border on the screen the cursor is currently on.
        if isHovered {
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            path.lineWidth = 6
            path.stroke()
        }
    }
}
