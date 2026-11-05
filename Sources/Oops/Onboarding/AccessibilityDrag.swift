import AppKit
import SwiftUI

/// The drop as something to drag: it carries Oops's own bundle the way Finder does, which is what
/// System Settings' Accessibility list accepts (PermissionFlow's payload). A click without a drag
/// opens the pane instead.
struct DropDragSource: NSViewRepresentable {
    var onBegin: () -> Void
    var onEnd: () -> Void
    var onClick: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DropDragView { update(DropDragView()) }
    func updateNSView(_ view: DropDragView, context: Context) { _ = update(view) }

    private func update(_ view: DropDragView) -> DropDragView {
        view.onBegin = onBegin; view.onEnd = onEnd; view.onClick = onClick; view.onHover = onHover
        return view
    }
}

final class DropDragView: NSView, NSDraggingSource {
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    private var down: NSPoint?
    private var dragging = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        down = convert(event.locationInWindow, from: nil); dragging = false
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - down.x, point.y - down.y) > 4 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: BundlePasteboardWriter(url: Bundle.main.bundleURL))
        let image = DropDragImage.image
        item.setDraggingFrame(NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging, down != nil { onClick() }
        down = nil; dragging = false
        window?.invalidateCursorRects(for: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onBegin() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        down = nil; dragging = false
        onEnd()
    }

    // VoiceOver gets the step's Open System Settings button instead: a drag isn't something it can do.
    override func isAccessibilityElement() -> Bool { false }
}

/// A Finder-style file drag of the app bundle: System Settings reads the file URL or the filenames list.
private final class BundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL
    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType"), .string]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL: url.absoluteString
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"): [url.path]
        case .string: url.path
        default: nil
        }
    }
}

/// What the pointer carries: the drop itself. Glass can't be rendered to an image, so the bead is a
/// dark translucent disc with a light rim, which holds on a light Settings list and a dark one alike.
@MainActor enum DropDragImage {
    private static var cached: NSImage?

    static var image: NSImage {
        if let cached { return cached }
        let renderer = ImageRenderer(content: Bead())
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 72, height: 72))
        cached = image
        return image
    }

    private struct Bead: View {
        var body: some View {
            Circle().fill(Color(white: 0.12).opacity(0.82))
                .overlay { Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1) }
                .overlay { DashEyes(look: CGSize(width: 0, height: -0.4), lid: 0, ink: .white, halo: .black.opacity(0.35)).padding(9) }
                .frame(width: 56, height: 56)
                .padding(8)
        }
    }
}

/// System Settings' window, as the window server reports it: no permission is needed to read a
/// window's bounds, which matters here because Accessibility isn't granted yet.
@MainActor enum SystemSettingsWindow {
    static let bundleID = "com.apple.systempreferences"

    static var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }

    /// Its largest on-screen window, in AppKit screen coordinates; nil when it isn't open.
    static var frame: CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return windows.compactMap { window -> CGRect? in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid, window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 320, rect.height > 240 else { return nil }
            return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        .max { $0.width * $0.height < $1.width * $1.height }
    }
}
