//
//  SelectionWindow.swift
//  PastScreen
//
//  Multi-screen selection window manager
//

import Foundation
import AppKit

// Protocol simple pour communiquer avec le service
protocol SelectionWindowDelegate: AnyObject {
    func selectionWindow(_ window: SelectionWindow, didSelectRect rect: CGRect)
    func selectionWindow(_ window: SelectionWindow, didSelectWindow windowResult: WindowHitTestResult)
    func selectionWindowDidCancel(_ window: SelectionWindow)
}

// MARK: - Overlay Window for Multi-Screen Support

class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Allow ESC to propagate to parent SelectionWindow
        if event.keyCode == 53 { // ESC
            // Will be handled by SelectionOverlayView
            super.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }
}

class SelectionWindow: NSWindow {
    weak var selectionDelegate: SelectionWindowDelegate?

    // Multi-screen support: one window per screen
    private var overlayWindows: [NSWindow] = []
    private let overlayConfiguration: SelectionOverlayView.Configuration

    init(overlayConfiguration: SelectionOverlayView.Configuration = .screenshot) {
        self.overlayConfiguration = overlayConfiguration
        // Create main window (first screen) for NSWindow inheritance
        let mainScreen = NSScreen.main ?? NSScreen.screens.first!

        super.init(
            contentRect: mainScreen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        setupMultiScreenOverlays()
    }

    private func setupMultiScreenOverlays() {
        // Create one window per screen
        for screen in NSScreen.screens {
            // Create window WITHOUT screen parameter to avoid auto-repositioning
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )

            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            // Manually position window to this screen's frame
            window.setFrame(screen.frame, display: false)

            // Create overlay view for this screen - frame must be relative to window (0,0 origin)
            let overlayFrame = NSRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
            let overlayView = SelectionOverlayView(frame: overlayFrame, configuration: overlayConfiguration)
            overlayView.onComplete = { [weak self] rect in
                guard let self = self else { return }
                self.selectionDelegate?.selectionWindow(self, didSelectRect: rect)
            }
            overlayView.onWindowSelect = { [weak self] hitResult in
                guard let self = self else { return }
                self.selectionDelegate?.selectionWindow(self, didSelectWindow: hitResult)
            }
            overlayView.onCancel = { [weak self] in
                guard let self = self else { return }
                self.selectionDelegate?.selectionWindowDidCancel(self)
            }

            window.contentView = overlayView
            overlayWindows.append(window)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            selectionDelegate?.selectionWindowDidCancel(self)
        } else {
            super.keyDown(with: event)
        }
    }

    // Convenience methods for showing/hiding
    func show() {
        // S'assurer que PastScreen devient app active pour capter le premier clic
        NSApp.activate(ignoringOtherApps: true)

        // Show all overlay windows - use orderFrontRegardless to force display
        for (index, window) in overlayWindows.enumerated() {
            // First window becomes key, others just order front
            if index == 0 {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
    }

    func hide() {
        // Hide all overlay windows immediately
        for window in overlayWindows {
            window.orderOut(nil)
            window.ignoresMouseEvents = true
        }
    }

    // Get overlay window IDs for ScreenCaptureKit exclusion
    func getOverlayWindowIDs() -> [CGWindowID] {
        let windowIDs = overlayWindows.compactMap { window -> CGWindowID? in
            let windowNumber = window.windowNumber
            guard windowNumber > 0 else { return nil }
            return CGWindowID(windowNumber)
        }
        return windowIDs
    }
}

// Vue simple pour dessiner la sélection
class SelectionOverlayView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onWindowSelect: ((WindowHitTestResult) -> Void)?
    var onCancel: (() -> Void)?
    
    struct Configuration {
        var overlayOpacity: CGFloat
        var clickThreshold: CGFloat
        var minSelectionSize: CGFloat

        static let screenshot = Configuration(overlayOpacity: 0.2, clickThreshold: 10, minSelectionSize: 10)
        static let ocr = Configuration(overlayOpacity: 0.2, clickThreshold: 2, minSelectionSize: 2)
    }

    private let configuration: Configuration

    private var startPoint: NSPoint?
    private var endPoint: NSPoint?
    private var isDragging = false
    private var pendingWindowHit: WindowHitTestResult?
    private var hoverWindowHit: WindowHitTestResult?
    private var highlightRect: NSRect?
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, configuration: Configuration = .screenshot) {
        self.configuration = configuration
        super.init(frame: frame)
        self.wantsLayer = true
        // Keep layer clear; dimming is drawn in draw(_:) to allow full transparency in the selection hole
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverWindowHit = resolveWindowHit()
        pendingWindowHit = hoverWindowHit
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // CRITICAL: Accept first mouse click even when app is not active
    // Without this, users need to click twice when Finder/Desktop is frontmost
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // CRITICAL: Don't delay window ordering when clicking
    // This ensures immediate event processing even when app was not frontmost
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        return false
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isDragging else { return }
        hoverWindowHit = resolveWindowHit()
        pendingWindowHit = hoverWindowHit
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        endPoint = startPoint
        isDragging = true
        pendingWindowHit = hoverWindowHit ?? resolveWindowHit()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        endPoint = convert(event.locationInWindow, from: nil)

        // Once user moves beyond the click threshold, switch to box selection
        if let start = startPoint, let end = endPoint {
            let deltaX = abs(end.x - start.x)
            let deltaY = abs(end.y - start.y)
            if max(deltaX, deltaY) > configuration.clickThreshold {
                pendingWindowHit = nil
                hoverWindowHit = nil
                highlightRect = nil
            }
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let start = startPoint, let end = endPoint else {
            // Defer callback to avoid crash during event handling
            DispatchQueue.main.async { [weak self] in
                self?.onCancel?()
            }
            return
        }

        isDragging = false

        let deltaX = abs(end.x - start.x)
        let deltaY = abs(end.y - start.y)
        let hasDragged = max(deltaX, deltaY) > configuration.clickThreshold

        if !hasDragged, let windowHit = pendingWindowHit {
            // Treat as window-click capture
            DispatchQueue.main.async { [weak self] in
                self?.onWindowSelect?(windowHit)
            }
            pendingWindowHit = nil
            highlightRect = nil
            startPoint = nil
            endPoint = nil
            return
        }

        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        // Defer callbacks to avoid crash when window is hidden/deallocated during event handling
        if rect.width > configuration.minSelectionSize && rect.height > configuration.minSelectionSize {
            DispatchQueue.main.async { [weak self] in
                self?.emitSelection(rect: rect)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onCancel?()
            }
        }

        pendingWindowHit = nil
        highlightRect = nil
        hoverWindowHit = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        isDragging = false
        startPoint = nil
        endPoint = nil
        pendingWindowHit = nil
        hoverWindowHit = nil
        highlightRect = nil
        needsDisplay = true

        DispatchQueue.main.async { [weak self] in
            self?.onCancel?()
        }
    }

    /// Convert local selection rect to global screen coordinates before sending
    private func emitSelection(rect: CGRect) {
        guard let window = self.window else {
            onCancel?()
            return
        }

        // Convert from view coordinates → window → screen to get the actual desktop rect
        let rectInWindow = convert(rect, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        onComplete?(rectOnScreen)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Fond semi-transparent plus marqué
        NSColor.black.withAlphaComponent(configuration.overlayOpacity).setFill()
        bounds.fill()

        var holeRect: NSRect?

        if let start = startPoint, let end = endPoint, (abs(end.x - start.x) > 0 || abs(end.y - start.y) > 0) {
            holeRect = NSRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        } else if let highlightRect {
            holeRect = highlightRect
        }

        guard let rect = holeRect else { return }

        // Zone claire
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        // Bordure
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Private helpers

    private func resolveWindowHit() -> WindowHitTestResult? {
        guard let window = self.window else { return nil }
        do {
            let hit = try WindowCaptureCoordinator.shared.hitTestFrontmostWindowAtMouse(
                excludingWindowIDs: Set([CGWindowID(window.windowNumber)]),
                skipSelfWindows: false
            )
            let rectOnScreen = hit.bounds
            let rectInWindow = window.convertFromScreen(rectOnScreen)
            let rectInView = convert(rectInWindow, from: nil)
            highlightRect = rectInView
            return hit
        } catch {
            highlightRect = nil
            return nil
        }
    }
}
