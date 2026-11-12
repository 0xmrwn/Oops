import AppKit
import ApplicationServices
import OopsCore

/// Copy and paste, for editors that expose no text, or only a hidden input proxy's: the selection
/// is read with ⌘C and the correction pasted over it. Nothing can confirm the result, so there is
/// no revert and no flash.
extension EditorAccess {
    /// The selection of an editor that exposes no text, read with ⌘C under a clipboard lease; the
    /// clipboard is put back after.
    func captureByCopy(_ opaque: OpaqueEditor) async throws -> EditorSnapshot {
        let shortcut = await ShortcutSettings.shared.label(.correct)
        if opaque.selected == false {
            throw CorrectionError.message("Oops can’t read this editor’s text. Select the text to fix, then press \(shortcut).")
        }
        try await KeyboardGate.waitForModifierRelease()
        // Waiting for the shortcut's keys to be let go gave focus time to move: copy only from the captured editor.
        try assertFocus(element: opaque.element, pid: opaque.pid, hostPID: opaque.hostPID, role: opaque.role)
        let lease = try ClipboardLease()
        defer { lease.restoreIfOwned() }
        if opaque.rejectCopiedLine {
            _ = AccessibilityExecution.perform(for: opaque.element) {
                AXUIElementSetAttributeValue(opaque.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            try assertFocus(element: opaque.element, pid: opaque.pid, hostPID: opaque.hostPID, role: opaque.role)
        }
        let copied = try copySelection(lease)
        // Code editors copy the whole current line, with its line break, when nothing is selected.
        let lineCopy = (opaque.empty != nil || opaque.rejectCopiedLine && opaque.selected != true) && copied?.last?.isNewline == true
        guard let copied, !copied.isEmpty, !lineCopy else {
            if let empty = opaque.empty { throw empty }
            throw CorrectionError.message("Oops can’t read this editor’s text. Select the text to fix, then press \(shortcut).")
        }
        // Pasting plain text back over an attachment or image would drop it, with no revert to bring it back.
        guard !copiedAttachment(copied) else {
            throw CorrectionError.message("This selection holds an attachment or image. Select text without attachments, then press \(shortcut).")
        }
        return opaque.snapshot(try TextTransaction(value: copied, selection: NSRange(location: 0, length: copied.utf16.count)))
    }

    /// Pastes the correction over the selection read at capture, once ⌘C shows it is still that text.
    /// The editor can't confirm the paste, so there is no revert.
    func applyByCopy(_ corrected: String, to snapshot: EditorSnapshot, clipboard: ClipboardLease, protected: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        try self.assertFocus(snapshot)
        guard protected() else { throw CorrectionError.message("The text-swap guard expired. Nothing replaced.") }
        guard let current = try self.copySelection(clipboard), sameText(current, snapshot.transaction.source) else {
            throw CorrectionError.message("The selection changed. Your correction is ready to copy.")
        }
        guard !copiedAttachment(current) else {
            throw CorrectionError.message("This selection holds an attachment or image. Select text without attachments. Nothing replaced.")
        }
        try Task.checkCancellation()
        try self.assertFocus(snapshot)
        guard protected() else { throw CorrectionError.message("The text-swap guard expired. Nothing replaced.") }
        try clipboard.install(corrected)
        // The clipboard is put back after the swap, so the app must have read the paste by then. An
        // input proxy shows it took the paste when its value or selection changes; an editor that
        // exposes nothing gives no such sign, so it gets a settle long enough for a key event's paste.
        let before = (text(snapshot.element, .value), range(snapshot.element))
        KeyboardGate.postCommand("v")
        if before.0 != nil || before.1 != nil {
            for _ in 0..<12 where text(snapshot.element, .value) == before.0 && range(snapshot.element) == before.1 {
                Thread.sleep(forTimeInterval: 0.025)
            }
        } else {
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    /// Whether the editor's own selection holds `expected`, as its copy command reads it. A paste
    /// replaces that selection, which some editors never take from Accessibility (Monaco outside
    /// Chrome, an editor inside a shadow root in Gecko) or take late (Slate adopts it on a throttled
    /// selectionchange). Copied again while the editor catches up, for up to half a second, with the
    /// selection written again first: Gecko drops a selection set through Accessibility that a key
    /// event overtakes.
    func editorHolds(_ expected: String, clipboard: ClipboardLease, reselect: () -> Void, validate: () throws -> Void) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var copies = 0, last: Int?
        repeat {
            try validate()
            if copies > 0 { reselect(); Thread.sleep(forTimeInterval: 0.05); try validate() }
            copies += 1
            let copied = try copySelection(clipboard, wait: 0.15)
            if let copied, sameText(Self.visible(copied), Self.visible(expected)) {
                if copies > 1 { Self.selectionLog.info("editor_selection_adopted copies=\(copies, privacy: .public)") }
                return true
            }
            last = copied?.utf16.count
        } while ProcessInfo.processInfo.systemUptime < deadline
        Self.selectionLog.notice("editor_selection_kept expected_len=\(expected.utf16.count, privacy: .public) copied_len=\(last ?? -1, privacy: .public) copies=\(copies, privacy: .public)")
        return false
    }

    /// Whether the editor still holds `draft`, as a copy of it reads in the order typed: a reading in
    /// display order and an edit that only moved characters (backticks moved onto a word) read the same,
    /// and only a copy tells them apart. The whole draft, so delimiters moved around `range`, the part
    /// corrected, show too; where the editor won't take the whole draft as a selection, the part alone,
    /// when nothing outside it could make it protected. The selection is put back to `restore` after.
    func copyHolds(_ draft: String, around range: NSRange, in snapshot: EditorSnapshot, restore: NSRange,
                   clipboard: ClipboardLease, validate: () throws -> Void) throws -> Bool {
        let whole = NSRange(location: 0, length: draft.utf16.count)
        // Put back while the editor is still the one in front, even if the swap's guard has expired: a whole
        // draft left selected would take the person's next keystroke.
        defer { if (try? assertTarget(snapshot)) != nil { _ = select(snapshot.element, restore, snapshot.strategy) } }
        for span in [whole, range] where span == whole || DisplayOrder.inert(outside: range, of: draft) {
            let expected = Self.visible((draft as NSString).substring(with: span))
            var taken = false, copiedAny = false
            // Written again before each try, for up to half a second: some editors adopt a selection late
            // (Slate, on a throttled handler) and copy the old one meanwhile, or drop it (Gecko).
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            repeat {
                try validate()
                _ = select(snapshot.element, span, snapshot.strategy)
                Thread.sleep(forTimeInterval: 0.05)
                try validate()
                guard selection(snapshot.element, snapshot.strategy) == span else { continue }
                taken = true
                if let copied = try copySelection(clipboard, wait: 0.15) {
                    copiedAny = true
                    var holds = DisplayOrder.copied(Self.visible(copied), matches: expected)
                    if !holds, !expected.contains(where: \.isNewline),
                       let html = NSPasteboard.general.string(forType: .html), let rich = CopiedHTML.inlineText(html) {
                        try clipboard.requireOwnership()
                        holds = DisplayOrder.copied(Self.visible(rich), matches: expected)
                    }
                    if holds {
                        Self.selectionLog.notice("draft_copied_display_order holds=true whole=\(span == whole, privacy: .public)")
                        return true
                    }
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard taken else { continue }
            guard copiedAny else { throw Self.uncopiable("copied=none") }
            Self.selectionLog.notice("draft_copied_display_order holds=false whole=\(span == whole, privacy: .public)")
            return false
        }
        throw Self.uncopiable("selection_not_taken")
    }

    /// The swap may go on: not cancelled, its guard still held, the editor still in front.
    nonisolated func stillSwapping(_ snapshot: EditorSnapshot, _ protected: () -> Bool) throws {
        try Task.checkCancellation()
        guard protected() else { throw CorrectionError.message("The text-swap guard expired. Nothing replaced.") }
        try assertTarget(snapshot)
    }

    private static func uncopiable(_ reason: String) -> DraftUncopiable {
        selectionLog.notice("draft_copied_display_order \(reason, privacy: .public)")
        return DraftUncopiable()
    }

    /// Fallback when Gecko can't select a word through its own leaf: a copy from the character before
    /// its whitespace through the word must prove the gap. Its value may flatten paragraph breaks to
    /// spaces (comboboxes), so every whitespace gap is checked. Starting inside the preceding text
    /// matters: RoosterJS's own selection can start at a paragraph's edge after a hidden empty line.
    func hidesEmptyLine(before edit: TextChange, in draft: String, element: AXUIElement, strategy: CaptureStrategy,
                        clipboard: ClipboardLease, validate: () throws -> Void) throws -> Bool {
        let text = draft as NSString
        let prefix = text.substring(to: edit.location)
        guard prefix.last?.isWhitespace == true else { return false }
        guard let previous = prefix.lastIndex(where: { !$0.isWhitespace }) else { return true }
        let start = prefix.utf16.distance(from: prefix.startIndex, to: previous)
        let span = NSRange(location: start, length: NSMaxRange(edit.range) - start)
        let expected = Self.visible(text.substring(with: span))
        var breaks = -1
        for _ in 0..<3 {
            try validate()
            _ = select(element, span, strategy)
            Thread.sleep(forTimeInterval: 0.05)
            try validate()
            guard let copied = try copySelection(clipboard, wait: 0.15) else { continue }
            if sameText(Self.visible(copied), expected) { return false }
            breaks = copied.filter(\.isNewline).count
        }
        Self.selectionLog.notice("empty_line_unproved copied_breaks=\(breaks, privacy: .public)")
        return true
    }

    /// Whether what was just copied holds an attachment or image: a U+FFFC in its text, an attachment
    /// in its rich text, or an image or embedded object in its HTML.
    func copiedAttachment(_ text: String) -> Bool {
        let board = NSPasteboard.general
        if text.contains("\u{FFFC}") || board.types?.contains(where: { [.rtfd, NSPasteboard.PasteboardType("com.apple.flat-rtfd")].contains($0) }) == true {
            return true
        }
        guard let html = board.string(forType: .html)?.lowercased() else { return false }
        return ["<img", "<object", "<embed", "<svg", "<picture"].contains { html.contains($0) }
    }

    /// ⌘C in the editor in front; nil when nothing was copied within `wait` (no selection) or it isn't text.
    func copySelection(_ lease: ClipboardLease, wait: TimeInterval = 0.4) throws -> String? {
        let board = NSPasteboard.general, before = board.changeCount
        KeyboardGate.postCommand("c")
        for _ in 0..<Int(wait / 0.02) where board.changeCount == before { Thread.sleep(forTimeInterval: 0.02) }
        guard board.changeCount != before else { return nil }
        lease.adopt()
        return board.string(forType: .string)
    }

    private func assertFocus(_ snapshot: EditorSnapshot) throws {
        try assertFocus(element: snapshot.element, pid: snapshot.pid, hostPID: snapshot.hostPID, role: snapshot.role)
    }

    /// The editor still has focus. An element that exposes nothing may not compare equal across
    /// reads, so one in the same process, window and role stands in for it.
    func assertFocus(element: AXUIElement, pid: pid_t, hostPID: pid_t?, role: String) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID ?? pid else {
            throw CorrectionError.message("Focus moved to another app. Your correction is ready to copy.")
        }
        let front = try focused()
        let focused = CFEqual(front, element) ? front : caretHolder(front) ?? front
        func window(_ node: AXUIElement) -> CFTypeRef? {
            attribute(node, kAXWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? $0 : nil }
        }
        let sameWindow = window(focused).flatMap { own in window(element).map { CFEqual(own, $0) } } ?? false
        guard self.pid(of: focused) == pid,
              CFEqual(focused, element) || sameWindow && attribute(focused, kAXRoleAttribute) as? String == role else {
            throw CorrectionError.message("Focus moved to another editor. Your correction is ready to copy.")
        }
    }
}

/// The editor wouldn't take a selection of the draft, or copy it, so a reading in display order can't be checked.
struct DraftUncopiable: LocalizedError {
    var errorDescription: String? { "This editor shows the draft in another order and wouldn’t let Oops copy it to check it. Nothing replaced." }
}
