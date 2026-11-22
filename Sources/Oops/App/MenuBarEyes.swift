import AppKit
import OopsCore

/// The wordmark's character, optically fitted to the status bar. AppKit supplies its ink.
@MainActor enum MenuBarEyes {
    static func configure(_ button: NSStatusBarButton) {
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Oops"
        button.setAccessibilityLabel("Oops")
        button.setAccessibilityHelp("Open Oops menu")
    }

    static let image = draw(nil)

    /// The eyes with an agent run's mark: a ring while it runs, a dot once its result is ready.
    static func image(_ mark: AgentRunFlow.MenuMark) -> NSImage {
        switch mark {
        case .none: image
        case .running: running
        case .ready: ready
        }
    }

    private static let running = draw(false), ready = draw(true)

    /// `filled`: nil draws the eyes alone; otherwise a small badge at the top right, a ring or a dot, with a clear
    /// margin cut around it so the two shapes stay apart in the bar's single ink.
    private static func draw(_ filled: Bool?) -> NSImage {
        let mark = BrandAssets.image("OopsMenuBar")
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            mark.draw(in: NSRect(x: 3, y: 1, width: 16, height: 16))
            guard let filled, let context = NSGraphicsContext.current else { return true }
            let badge = NSRect(x: 16.5, y: 12.5, width: 5, height: 5)
            context.compositingOperation = .clear
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.25, dy: -1.25)).fill()
            context.compositingOperation = .sourceOver
            NSColor.black.set()
            if filled {
                NSBezierPath(ovalIn: badge).fill()
            } else {
                let ring = NSBezierPath(ovalIn: badge.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Oops"
        return image
    }
}
