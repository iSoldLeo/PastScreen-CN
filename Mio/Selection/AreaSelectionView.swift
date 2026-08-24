//
//  AreaSelectionView.swift
//  Mio
//
//  Module 05 area/window selection surface. One instance per frozen display.
//  It draws the frozen snapshot, resolves hover/click via the live Quartz
//  WindowHitTester (v2.0.0 window logic), and emits a typed
//  AreaSelectionDecision to its owning presentation. The view's own coordinate
//  space is the display's AppKit points (origin bottom-left), so a view-local
//  selection rect IS already display-local — no centre guessing.
//

import AppKit

@MainActor
final class AreaSelectionView: NSView {
    struct Configuration {
        var overlayOpacity: CGFloat
        var clickThreshold: CGFloat
        var minSelectionSize: CGFloat

        static let screenshot = Configuration(overlayOpacity: 0.2, clickThreshold: 10, minSelectionSize: 10)
    }

    /// Called exactly through the owning presentation's one-shot gate; the
    /// presentation detaches this on finish so late gestures are ignored.
    var onDecision: ((AreaSelectionDecision) -> Void)?

    private let configuration: Configuration
    let displayID: CGDirectDisplayID
    private let backgroundImage: CaptureImage

    private var startPoint: NSPoint?
    private var endPoint: NSPoint?
    private var isDragging = false
    private var pendingWindowHit: WindowHitTestResult?
    private var hoverWindowHit: WindowHitTestResult?
    private var highlightRect: NSRect?
    private var trackingArea: NSTrackingArea?

    init(
        frame: NSRect,
        configuration: Configuration = .screenshot,
        displayID: CGDirectDisplayID,
        backgroundImage: CaptureImage
    ) {
        self.configuration = configuration
        self.displayID = displayID
        self.backgroundImage = backgroundImage
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
        hoverWindowHit = nil
        pendingWindowHit = nil
        highlightRect = nil
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

    // Accept the first click and process it immediately even when Mio is not
    // the active app (the overlay is a nonactivating panel).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // Escape via the responder chain of the nonactivating key panel — no global
    // monitor, no Accessibility dependency.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onDecision?(.cancelled(.user(.escape)))
            return
        }
        super.keyDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isDragging else { return }
        let previousHighlight = highlightRect
        hoverWindowHit = resolveWindowHit()
        pendingWindowHit = hoverWindowHit
        if highlightRect != previousHighlight {
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        endPoint = startPoint
        isDragging = true
        pendingWindowHit = resolveWindowHit()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        endPoint = convert(event.locationInWindow, from: nil)
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
            onDecision?(.cancelled(.user(.tooSmall)))
            return
        }
        isDragging = false

        let deltaX = abs(end.x - start.x)
        let deltaY = abs(end.y - start.y)
        let hasDragged = max(deltaX, deltaY) > configuration.clickThreshold

        if !hasDragged, let windowHit = pendingWindowHit {
            resetInteractionState()
            onDecision?(.window(WindowSelection(descriptor: descriptor(from: windowHit))))
            return
        }

        // View-local rect is already display-local AppKit points; clamp to the
        // originating display bounds so 05 (not 06) owns the single-source
        // policy (C05-D2) — no out-of-bounds CropRequest leaves this view.
        let rawRect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        let rect = rawRect.intersection(bounds)
        resetInteractionState()

        if !rect.isNull, rect.width > configuration.minSelectionSize, rect.height > configuration.minSelectionSize {
            onDecision?(.rectangle(CropRequest(displayID: displayID, rectInDisplayPoints: rect)))
        } else {
            onDecision?(.cancelled(.user(.tooSmall)))
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        resetInteractionState()
        needsDisplay = true
        onDecision?(.cancelled(.user(.rightClick)))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let context = NSGraphicsContext.current?.cgContext {
            context.draw(backgroundImage.cgImage, in: bounds)
        }

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

        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.clip(to: rect)
            context.draw(backgroundImage.cgImage, in: bounds)
            context.restoreGState()
        }

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func resetInteractionState() {
        pendingWindowHit = nil
        hoverWindowHit = nil
        highlightRect = nil
        startPoint = nil
        endPoint = nil
    }

    private func resolveWindowHit() -> WindowHitTestResult? {
        guard let window = self.window else { return nil }
        guard let hit = WindowHitTester.hitTestAtMouse() else {
            highlightRect = nil
            return nil
        }
        let rectInWindow = window.convertFromScreen(hit.bounds)
        highlightRect = convert(rectInWindow, from: nil)
        return hit
    }

    /// Build the on-demand capture descriptor from a live hit. It was
    /// selectable by construction (it passed the live hit-test), and its
    /// display is the panel the click landed on.
    private func descriptor(from hit: WindowHitTestResult) -> CaptureWindowDescriptor {
        CaptureWindowDescriptor(
            windowID: hit.windowID,
            frameInAppKitPoints: hit.bounds,
            primaryDisplayID: displayID,
            ownerPID: hit.ownerPID,
            layer: hit.layer,
            frontToBackIndex: 0,
            isSelectable: true
        )
    }
}
