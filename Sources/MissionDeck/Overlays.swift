import AppKit

/// Borderless, click-through panels drawn above Mission Control.
/// Clicks are handled by the event tap, not by these windows, so they never
/// steal focus or dismiss Mission Control.
final class Overlays {
    private let closePanel: NSPanel
    private let ringPanel: NSPanel
    private var closeFrame = NSRect.zero
    private var ringFrame = NSRect.zero

    init() {
        closePanel = Overlays.makePanel(CloseButtonView(), shadow: true)
        ringPanel = Overlays.makePanel(SelectionRingView(), shadow: false)
    }

    /// The ✕ is centered exactly on the window picture's top-left corner:
    /// half of it sits on the window, half outside, right on the edge.
    static func closeButtonRect(for window: CGRect, size: CGFloat) -> CGRect {
        CGRect(x: window.minX - size / 2, y: window.minY - size / 2, width: size, height: size)
    }

    /// Slightly larger than the drawn button, so it's easy to hit.
    static func closeButtonHitRect(for window: CGRect, size: CGFloat) -> CGRect {
        closeButtonRect(for: window, size: size).insetBy(dx: -6, dy: -6)
    }

    func showCloseButton(for window: CGRect, size: CGFloat) {
        let frame = Overlays.toCocoa(Overlays.closeButtonRect(for: window, size: size))
        if frame != closeFrame {
            closeFrame = frame
            closePanel.setFrame(frame, display: true)
            closePanel.contentView?.needsDisplay = true
        }
        if !closePanel.isVisible { closePanel.orderFrontRegardless() }
    }

    func hideCloseButton() {
        if closePanel.isVisible { closePanel.orderOut(nil) }
    }

    func showRing(around window: CGRect) {
        let frame = Overlays.toCocoa(window.insetBy(dx: -6, dy: -6))
        if frame != ringFrame {
            ringFrame = frame
            ringPanel.setFrame(frame, display: true)
        }
        if !ringPanel.isVisible {
            ringPanel.orderFrontRegardless()
            if closePanel.isVisible { closePanel.orderFrontRegardless() }   // keep ✕ on top
        }
    }

    func hideRing() {
        if ringPanel.isVisible { ringPanel.orderOut(nil) }
    }

    func hideAll() {
        hideCloseButton()
        hideRing()
    }

    /// Accessibility uses a top-left origin; AppKit uses bottom-left of the primary screen.
    static func toCocoa(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func makePanel(_ view: NSView, shadow: Bool) -> NSPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        // .stationary keeps the panel out of Mission Control's own window shuffling.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = view
        return panel
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CloseButtonView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)

        let circle = NSBezierPath(ovalIn: rect)
        NSColor(calibratedWhite: 0.1, alpha: 0.9).setFill()
        circle.fill()
        NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()   // white rim so it reads on any window
        circle.lineWidth = max(1.5, rect.width * 0.05)
        circle.stroke()

        let inset = rect.width * 0.32
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        cross.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        cross.move(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        cross.line(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        cross.lineWidth = max(2, rect.width * 0.08)
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }
}

private final class SelectionRingView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
        path.lineWidth = 4
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        path.stroke()
    }
}
