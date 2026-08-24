//
//  ScreenChoiceView.swift
//  Mio
//
//  Module 05 multi-display screen-chooser surface. One instance per frozen
//  display. Draws the per-screen frozen snapshot, highlights on hover, and
//  emits a typed ScreenChoiceDecision to its owning presentation.
//

import AppKit

@MainActor
final class ScreenChoiceView: NSView {
    /// Routed through the owning presentation's one-shot gate.
    var onDecision: ((ScreenChoiceDecision) -> Void)?

    private let displayID: CGDirectDisplayID
    private let backgroundImage: CaptureImage
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, displayID: CGDirectDisplayID, backgroundImage: CaptureImage) {
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
        isHovered = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onDecision?(.cancelled(.user(.escape)))
            return
        }
        super.keyDown(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onDecision?(.selected(displayID))
    }

    override func rightMouseDown(with event: NSEvent) {
        onDecision?(.cancelled(.user(.rightClick)))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let context = NSGraphicsContext.current?.cgContext {
            context.draw(backgroundImage.cgImage, in: bounds)
        }

        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        if isHovered {
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            path.lineWidth = 6
            path.stroke()
        }
    }
}
