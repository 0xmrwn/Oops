import CoreGraphics

/// Where the capsule goes, from the focused editor's Accessibility geometry. Everything is in AX
/// points: top-left origin, global, relative to the primary display. Each rule comes from a placement probe of
/// the browser and native editor engines.
public enum CapsulePlacement {
    public struct Ancestor: Equatable, Sendable {
        public var role: String, frame: CGRect
        public init(role: String, frame: CGRect) { self.role = role; self.frame = frame }
    }
    public struct Geometry: Equatable, Sendable {
        public var element: CGRect?
        /// Innermost first.
        public var ancestors: [Ancestor]
        public var window: CGRect?
        public var caret: CGRect?
        public var previousCharacter: CGRect?
        public init(element: CGRect?, ancestors: [Ancestor] = [], window: CGRect? = nil,
                    caret: CGRect? = nil, previousCharacter: CGRect? = nil) {
            self.element = element; self.ancestors = ancestors; self.window = window
            self.caret = caret; self.previousCharacter = previousCharacter
        }
    }
    /// The envelope corner the capsule hugs, so a longer label grows away from the anchor.
    public enum Corner: Sendable { case bottomTrailing, topTrailing, bottomLeading, topLeading, bottom }
    public enum Strategy: String, Sendable { case composer, composerBelow, caret, caretAbove, window, screen }
    public struct Placement: Equatable, Sendable {
        /// The area the capsule may occupy at its largest.
        public var envelope: CGRect, corner: Corner, strategy: Strategy
    }

    /// A caret is only trusted in document-like boxes: at least this tall and this share of the
    /// window. Chat composers, even grown ones, anchor to their edge (below the caret is their toolbar).
    static let caretBoxHeight: CGFloat = 160, caretBoxShare: CGFloat = 0.4
    /// Standard window title bar height; "above" never covers it.
    static let titleBar: CGFloat = 28
    /// How far a composer's box may reach above its text area: Claude's and Codex's rounded boxes pad
    /// it by 12–14 pt; Teams' 27 pt belongs to an invisible container around its visible box.
    static let topPadding: CGFloat = 20

    public static func place(_ geometry: Geometry?, envelope size: CGSize, screens: [CGRect], gap: CGFloat = 8) -> Placement {
        let box = geometry.flatMap(composerBox)
        let caret = geometry.flatMap { self.caret($0, within: box) }
        let screen = bestScreen(for: box ?? geometry?.window, in: screens)
        let bounds = screen.insetBy(dx: 8, dy: 8)
        // Above an editor means inside its window, below the title bar, not over the chrome.
        let top = max(bounds.minY, geometry?.window.flatMap { valid($0) ? $0.minY + titleBar : nil } ?? bounds.minY)
        func fits(_ rect: CGRect) -> Bool { rect.minY >= top && rect.maxY <= bounds.maxY }
        func result(_ rect: CGRect, _ corner: Corner, _ strategy: Strategy) -> Placement {
            Placement(envelope: clamp(rect, into: bounds), corner: corner, strategy: strategy)
        }
        let window = geometry?.window.flatMap { valid($0) && $0.width > 0 && $0.height > 0 ? $0 : nil }
        let documentLike = box.map { $0.height > max(caretBoxHeight, caretBoxShare * (window?.height ?? 0)) } ?? false
        if let caret, documentLike {
            // Below the caret line, like the system's input indicators: while typing at the end,
            // that space is empty, whereas above it is the text just written. Near the right edge
            // (right-to-left text) the capsule grows leftward from the caret instead.
            let right = min(bounds.maxX, window?.maxX ?? bounds.maxX)
            let leading = caret.minX - 12 + size.width <= right
            let x = leading ? caret.minX - 12 : caret.maxX + 12 - size.width
            let below = CGRect(x: x, y: caret.maxY + gap, width: size.width, height: size.height)
            if fits(below) { return result(below, leading ? .topLeading : .topTrailing, .caret) }
            return result(below.offsetBy(dx: 0, dy: -(caret.height + 2 * gap + size.height)), leading ? .bottomLeading : .bottomTrailing, .caretAbove)
        }
        // A window-filling document with no usable caret has no "above" or "below": use the window.
        if let box, !(window.map { pageSized(box, in: $0) } ?? false) {
            let above = CGRect(x: box.maxX - size.width, y: box.minY - gap - size.height, width: size.width, height: size.height)
            if fits(above) { return result(above, .bottomTrailing, .composer) }
            return result(above.offsetBy(dx: 0, dy: box.height + 2 * gap + size.height), .topTrailing, .composerBelow)
        }
        if let window, window.width >= size.width, window.height >= size.height * 2 {
            let rect = CGRect(x: window.midX - size.width / 2, y: window.maxY - 24 - size.height, width: size.width, height: size.height)
            return result(rect, .bottom, .window)
        }
        let rect = CGRect(x: screen.midX - size.width / 2, y: screen.maxY - 90 - size.height, width: size.width, height: size.height)
        return result(rect, .bottom, .screen)
    }

    /// The visible composer: the focused text area, widened through ancestors that stay close to it
    /// (Claude's rounded box with its toolbar, Codex's box but not its full-width bar, Teams' bordered
    /// field but not the padded container around it, an AppKit scroll view).
    static func composerBox(_ geometry: Geometry) -> CGRect? {
        guard var element = geometry.element, valid(element) else { return nil }
        // Never the page: a web area, or anything covering most of the window.
        let window = geometry.window.flatMap { valid($0) && $0.width > 0 && $0.height > 0 ? $0 : nil }
        func pageSized(_ frame: CGRect) -> Bool { window.map { CapsulePlacement.pageSized(frame, in: $0) } ?? false }
        var ancestors = geometry.ancestors[...]
        // A hidden input proxy stands for the editor drawn around it: its nearest ancestor with a box.
        if isInputProxy(element) {
            guard let host = ancestors.firstIndex(where: { !["AXWindow", "AXApplication", "AXSheet", "AXWebArea"].contains($0.role)
                && valid($0.frame) && $0.frame.width >= 20 && $0.frame.height >= 8 && !pageSized($0.frame)
            }) else { return nil }
            element = ancestors[host].frame
            ancestors = ancestors[(host + 1)...]
        }
        guard element.width >= 20, element.height >= 8 else { return nil }
        var box = element
        for ancestor in ancestors {
            let frame = ancestor.frame
            guard !["AXWindow", "AXApplication", "AXSheet", "AXWebArea"].contains(ancestor.role), valid(frame), !pageSized(frame),
                  frame.insetBy(dx: -1, dy: -1).contains(box),
                  frame.width <= element.width * 1.25 + 4, frame.height <= element.height + 140,
                  element.minY - frame.minY <= topPadding else { break }
            box = frame
        }
        // Only the visible part counts: a document text view is as tall as its text, and an
        // element can be laid out wider than its window. Clip to the scroll view and the window.
        if let scroll = geometry.ancestors.first(where: { $0.role == "AXScrollArea" && valid($0.frame) && $0.frame.intersects(element) }) {
            box = box.intersection(scroll.frame)
        }
        if let window { box = box.intersection(window) }
        guard !box.isNull, box.width >= 20, box.height >= 8 else { return nil }
        return box
    }

    /// A text input too small to show its own text: the hidden textarea or contenteditable a canvas
    /// or painted editor takes keys through.
    public static func isInputProxy(_ frame: CGRect) -> Bool { min(frame.width, frame.height) < 4 }

    static func pageSized(_ frame: CGRect, in window: CGRect) -> Bool {
        let overlap = frame.intersection(window)
        return !overlap.isNull && overlap.width * overlap.height >= 0.8 * window.width * window.height
    }

    /// A caret rect worth trusting. Chromium encodes "none" as zero-size rects at the screen-bottom
    /// or window origin; AppKit reports a line-end caret on the previous line.
    static func caret(_ geometry: Geometry, within box: CGRect?) -> CGRect? {
        guard let box else { return nil }
        let area = box.insetBy(dx: -4, dy: -4)
        func usable(_ rect: CGRect?) -> CGRect? {
            guard let rect, valid(rect), rect.height > 0, rect.height <= 200, area.intersects(rect) else { return nil }
            return rect
        }
        if let previous = usable(geometry.previousCharacter), previous.width <= 60 {
            if let caret = usable(geometry.caret), caret.width <= 10, previous.minY <= caret.midY { return caret }
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        guard let caret = usable(geometry.caret), caret.width <= 10 else { return nil }
        return caret
    }

    static func bestScreen(for rect: CGRect?, in screens: [CGRect]) -> CGRect {
        guard let first = screens.first else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        guard let rect, valid(rect) else { return first }
        let area = { (screen: CGRect) -> CGFloat in let i = screen.intersection(rect); return i.isNull ? 0 : i.width * i.height }
        return screens.max { area($0) < area($1) }.flatMap { area($0) > 0 ? $0 : nil } ?? first
    }

    static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        rect.origin.y = min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return rect
    }

    static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width >= 0 && rect.height >= 0
    }
}
