import AppKit
import OSLog
import OopsCore

/// The steps a correction shares with taking it back and putting it back: the guarded swap and the
/// in-place flash.
extension CorrectionSession {
    /// The guarded swap correct and revert share: wait for Hyper to be let go, lease the clipboard,
    /// hold input for the paste, then give both back. Returns the swap's milliseconds, or nil when a
    /// newer request took over before it began.
    func swap(_ id: UUID, validate: () throws -> Void = {},
              _ replace: (ClipboardLease, @escaping @Sendable () -> Bool) async throws -> Void) async throws -> Int? {
        try await KeyboardGate.waitForModifierRelease()
        let started = ContinuousClock.now
        let clipboard = try await editor.prepareClipboard()
        try Task.checkCancellation()
        guard generation == id else { return nil }
        try validate()
        let gate = try KeyboardGate()
        committing = true; capsule.model.canCancel = false
        defer { gate.release(); committing = false; capsule.model.canCancel = true; clipboard.restoreIfOwned() }
        try await replace(clipboard) { gate.isActive }
        return DebugLog.milliseconds(since: started)
    }

    /// The in-place flash over another app's draft, which now reads `text`: `ranges` shift by `offset`,
    /// where the text they were measured in starts in the full draft. Try flashes its own text view instead.
    func flashHighlights(_ ranges: [NSRange], in snapshot: EditorSnapshot, holding text: String, offset: Int,
                         style: HighlightOverlay.Style, remounted: Bool = false) async {
        guard snapshot.pid != getpid() || DebugFlags.highlightOverlayEverywhere else { return }
        // The app may have remounted the editor since the swap.
        let snapshot = await editor.following(snapshot, holding: text)
        let shifted = ranges.map { NSRange(location: $0.location + offset, length: $0.length) }
        var rects = await editor.highlightRects(for: shifted, in: snapshot)
        // Remounted while it was measured: measure the new editor.
        if rects.isEmpty { rects = await editor.highlightRects(for: shifted, in: editor.following(snapshot, holding: text)) }
        // A rebuilt editor may still be laying out: measure until two readings agree.
        if remounted {
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(50))
                let again = await editor.highlightRects(for: shifted, in: editor.following(snapshot, holding: text), quiet: true)
                if again == rects { break }
                rects = again
            }
        }
        guard !Task.isCancelled, let first = shifted.first(where: { $0.length > 0 }) else { return }
        highlight.flash(rects, style: style, element: snapshot.element) { [weak self] in
            guard let editor = self?.editor else { return nil }
            return await editor.highlightRects(for: [first], in: editor.following(snapshot, holding: text), quiet: true).first
        }
    }
}
