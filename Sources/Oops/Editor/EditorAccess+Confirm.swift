import AppKit
import ApplicationServices
import OSLog
import OopsCore

/// A paste went in, and the editor never showed the text it should hold.
struct UnconfirmedPaste: LocalizedError {
    /// The fix went in, but the editor changed other text beside it.
    var beside = false
    var errorDescription: String? {
        beside ? "The fix went in, but the editor also changed text near it. Check the draft; the original is available in the menu."
            : "The editor did not confirm the replacement. Check the draft before retrying; the original is available in the menu."
    }
}

/// The editor pasted at a selection of its own, and its undo took exactly that back.
struct UndonePaste: LocalizedError {
    var errorDescription: String? { "The editor put the fix in the wrong place, so Oops undid it. Nothing replaced." }
}

/// A paste would land on a selection the editor kept, not the one Oops made.
struct EditorKeptSelection: LocalizedError {
    var errorDescription: String? { "The editor kept its own selection, so the fix couldn’t be placed. Nothing replaced." }
}

/// How the swap knows the editor did what Oops asked: its selected text, a paste confirmed in its
/// text, an editor the app remounted followed to its new element, and a paste the editor put at a
/// selection of its own taken back.
extension EditorAccess {
    /// Whether the editor reports `expected` as its selected text, read again while its Accessibility
    /// cache catches up with a new selection (Chromium's lags the range by a frame or two). Nil when
    /// it reports no selected text, as some toolkits don't.
    nonisolated func selectedTextMatches(_ element: AXUIElement, _ expected: String, at location: Int = 0) -> Bool? {
        var length = 0, differs = -1, landed = "none"
        for read in 1...8 {
            guard let selected = attribute(element, kAXSelectedTextAttribute) as? String, !selected.isEmpty else { return nil }
            // Where the selection really landed in the value, against the invisible characters before it.
            if let value = attribute(element, kAXValueAttribute) as? String {
                let ns = value as NSString, near = ns.range(of: selected, options: [], range: NSRange(location: 0, length: ns.length))
                let before = (value.utf16.prefix(max(0, min(location, ns.length))).map(\.self)).filter { [0xFEFF, 0x200B, 0x2060].contains($0) }.count
                landed = near.location == NSNotFound ? "none invisible_before=\(before)" : "delta=\(near.location - location) invisible_before=\(before)"
                if let marked = markerText(element) {
                    let found = (marked as NSString).range(of: selected)
                    landed += found.location == NSNotFound ? " markers=none" : " markers_delta=\(found.location - location)"
                }
            }
            length = selected.utf16.count
            differs = zip(Self.visible(selected).unicodeScalars, Self.visible(expected).unicodeScalars).prefix { $0 == $1 }.count
            if sameText(Self.visible(selected), Self.visible(expected)) {
                if read > 1 { Self.selectionLog.info("selected_text_confirmed_after_wait reads=\(read, privacy: .public)") }
                return true
            }
            if read < 8 { Thread.sleep(forTimeInterval: 0.025) }
        }
        Self.selectionLog.notice("selected_text_mismatch expected_len=\(expected.utf16.count, privacy: .public) selected_len=\(length, privacy: .public) same_scalars=\(differs, privacy: .public) \(landed, privacy: .public)")
        return false
    }

    static let selectedDifferentText = CorrectionError.message("The editor selected different text than the fix replaces. Nothing replaced.")

    /// Text as it shows: without the invisible characters editors pad atoms and empty lines with, and
    /// with non-breaking spaces as spaces.
    static func visible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.compactMap {
            ["\u{FEFF}", "\u{200B}", "\u{2060}"].contains($0) ? nil : $0 == "\u{00A0}" ? " " : $0
        }))
    }

    /// The span to select so the editor selects the edit's text, when its ranges sit a few units off
    /// its text around atoms (Chromium counts an image by its alt text): aimed once by where the
    /// first selection landed, and confirmed by the selected text again.
    func aim(_ edit: TextChange, in snapshot: EditorSnapshot, validate: () throws -> Void) throws -> NSRange {
        let element = snapshot.element, strategy = snapshot.strategy
        guard let selected = attribute(element, kAXSelectedTextAttribute) as? String, let current = text(element, strategy),
              let landed = TextOffsets.nearest(selected, in: current, to: edit.location, within: 8)
                ?? (markerText(element)?.contains("\u{FFFC}") == true
                    ? TextOffsets.uniqueOccurrence(selected, in: current, to: edit.location, within: 32) : nil), landed != edit.location,
              let aimed = TextOffsets.plausible(location: edit.location - (landed - edit.location), length: edit.range.length) else {
            throw Self.selectedDifferentText
        }
        try SelectionConfirmation.require(aimed, write: { self.select(element, aimed, strategy) },
                                          read: { self.selection(element, strategy) }, validate: validate)
        guard selectedTextMatches(element, edit.original) == true else {
            throw Self.selectedDifferentText
        }
        Self.selectionLog.notice("selection_aimed offset=\(landed - edit.location, privacy: .public)")
        return aimed
    }

    /// A span next to the edit's, when the editor ignored a selection it couldn't place (Chromium with
    /// an image in right-to-left text): the nearest whose selection reads back and holds the edit's text.
    func nearby(_ edit: TextChange, in snapshot: EditorSnapshot, validate: () throws -> Void) throws -> NSRange {
        let element = snapshot.element, strategy = snapshot.strategy
        for shift in [-1, 1, -2, 2] {
            guard let shifted = TextOffsets.plausible(location: edit.location + shift, length: edit.range.length),
                  (try? SelectionConfirmation.require(shifted, write: { self.select(element, shifted, strategy) },
                                                      read: { self.selection(element, strategy) }, validate: validate)) != nil,
                  selectedTextMatches(element, edit.original) == true else { continue }
            Self.selectionLog.notice("selection_nearby offset=\(shift, privacy: .public)")
            return shifted
        }
        try validate()
        throw SelectionConfirmation.Failure.unconfirmed(expected: edit.range, observed: selection(element, strategy))
    }

    /// A paste the editor put at a selection of its own, which neither Accessibility nor a copy could
    /// show (Quill inside a shadow root pastes at the selection it last saw). When the text is provably
    /// the draft with this paste somewhere else, the editor's own undo takes it back, but only an exact
    /// return to the text before the paste counts: an undo grouped with the person's own last edits
    /// goes further, so it is redone at once, and the text left as the paste made it.
    func undoMisplaced(_ pasted: String, in snapshot: EditorSnapshot, over draft: String, giving next: String) throws {
        guard let misplaced = text(snapshot.element, snapshot.strategy), !sameDraft(misplaced, next),
              TextEdits.misplaced(pasted, in: misplaced, over: draft), (try? assertTarget(snapshot)) != nil else { return }
        func read() -> TextEdits.Undo {
            text(snapshot.element, snapshot.strategy).map { TextEdits.undo($0, before: draft, misplaced: misplaced) } ?? .overshot
        }
        KeyboardGate.postCommand("z")
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var outcome = TextEdits.Undo.pending
        repeat {
            outcome = read()
            if outcome == .restored { Self.selectionLog.notice("misplaced_paste_undone"); throw UndonePaste() }
            // Anything else must hold for a moment, so a half-read change isn't taken for an overshoot.
            if outcome == .overshot {
                Thread.sleep(forTimeInterval: 0.1)
                outcome = read()
                if outcome == .restored { Self.selectionLog.notice("misplaced_paste_undone"); throw UndonePaste() }
                if outcome == .overshot { break }
            }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard outcome == .overshot else { Self.selectionLog.notice("misplaced_paste_kept undo=none"); return }
        KeyboardGate.postCommand("z", shift: true)
        let redone = ProcessInfo.processInfo.systemUptime + 1
        repeat {
            if read() == .pending { Self.selectionLog.notice("misplaced_paste_kept undo=redone"); return }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < redone
        Self.selectionLog.notice("misplaced_paste_kept undo=unknown")
    }

    /// Waits for the editor to show `next` after a paste at `pasted` over `draft`, following it if the app
    /// rebuilt it around the pasted text. Up to a second: Chromium reports an edit only once it serializes
    /// its accessibility tree again, which can take hundreds of milliseconds while its switch settles.
    /// In web content, a reading in display order counts as `DisplayOrder.confirms` allows.
    /// `distinct` is only asked for when a reading in display order needs it; `weakly` is set when only it
    /// confirmed the paste (see `DisplayOrder.confirms`), so the caller proves the result by a copy.
    func confirm(_ snapshot: inout EditorSnapshot, holding next: String, over draft: String, pasted: NSRange,
                 distinct: @escaping () -> Bool, weakly: inout Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        let web = snapshot.webContent
        let gecko = web && Self.isGecko(snapshot)
        var known: Bool?, weak = false
        defer { weakly = weakly || weak }
        let shows = { (text: String) -> Bool in
            if sameDraft(text, next) || web && DisplayOrder.reordered(text, of: next, awayFrom: pasted) { return true }
            guard web, DisplayOrder.confirms(text, next: next, draft: draft, pasted: pasted, distinct: {
                if known == nil { known = distinct() }
                return known!
            }()) else { return false }
            weak = true
            return true
        }
        repeat {
            if let current = text(snapshot.element, snapshot.strategy), shows(current) {
                if !sameDraft(current, next) { Self.selectionLog.notice("paste_confirmed_display_order") }
                return true
            }
            if let moved = remounted(snapshot, holding: next, accepting: shows) { snapshot.element = moved; return true }
            // Chromium can leave the value stale indefinitely. Gecko's value instead catches up;
            // keep its character-coordinate reading through that lag rather than switching mid-swap.
            if !gecko, snapshot.strategy == .value, let marked = markerText(snapshot.element), shows(marked) {
                let role = snapshot.role, ordered = !sameDraft(marked, next)
                Self.selectionLog.notice("value_stale_markers_current role=\(role, privacy: .public) display_order=\(ordered, privacy: .public)")
                snapshot.strategy = .atoms
                return true
            }
            Thread.sleep(forTimeInterval: 0.025)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// Whether `text`, the editor's reading, is the draft `typed`: the same, or in web content the same
    /// characters in display order (see `DisplayOrder`).
    nonisolated func reads(_ text: String, as typed: String, _ snapshot: EditorSnapshot) -> Bool {
        sameDraft(text, typed) || Self.displayOrdered(text, typed, snapshot)
    }

    nonisolated static func displayOrdered(_ text: String, _ typed: String, _ snapshot: EditorSnapshot) -> Bool {
        snapshot.webContent && DisplayOrder.reordered(text, of: typed)
    }

    /// Whether the element reports its selected text and markers in display order while its value
    /// keeps the order typed (Chromium, with mixed-direction text): its selected text then can't
    /// confirm a selection, and the copy check does instead.
    nonisolated func displayOrdered(_ element: AXUIElement) -> Bool {
        guard let value = attribute(element, kAXValueAttribute) as? String, let marked = markerText(element) else { return false }
        return DisplayOrder.reordered(marked, of: value)
    }

    /// The editor that replaced the snapshot's when the app remounted it after an edit (a new React
    /// key, a new SwiftUI identity): the focused element in the same process and window, with the
    /// same role and the text Oops expects there (as `reads` takes it, or as `accepting` does). Nil when
    /// focus is anywhere else.
    nonisolated func remounted(_ snapshot: EditorSnapshot, holding text: String, accepting: ((String) -> Bool)? = nil) -> AXUIElement? {
        if let hostPID = snapshot.hostPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != hostPID { return nil }
        guard let window = snapshot.window, let raw = try? focused() else { return nil }
        let focused = caretHolder(raw) ?? raw
        guard pid(of: focused) == snapshot.pid,
              !CFEqual(focused, snapshot.element), attribute(focused, kAXRoleAttribute) as? String == snapshot.role,
              let own = attribute(focused, kAXWindowAttribute), CFEqual(own, window),
              let value = self.text(focused, snapshot.strategy), accepting?(value) ?? reads(value, as: text, snapshot) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        Self.selectionLog.notice("editor_remounted role=\(snapshot.role, privacy: .public)")
        return focused
    }

    /// The snapshot's editor still has focus, or was remounted holding `text`: then the snapshot
    /// follows it.
    nonisolated func follow(_ snapshot: inout EditorSnapshot, holding text: String) throws {
        do { try assertTarget(snapshot) } catch {
            // React can discard the old AX node before the new node's text is serialized.
            // Follow only the same process/window/role once its expected draft is readable.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            repeat {
                if let moved = remounted(snapshot, holding: text) { snapshot.element = moved; return }
                Thread.sleep(forTimeInterval: 0.025)
            } while ProcessInfo.processInfo.systemUptime < deadline
            throw error
        }
    }

    /// The snapshot with the editor that now holds `text`: its own, or the one the app remounted.
    func following(_ snapshot: EditorSnapshot, holding text: String) -> EditorSnapshot {
        var snapshot = snapshot
        try? follow(&snapshot, holding: text)
        return snapshot
    }
}
