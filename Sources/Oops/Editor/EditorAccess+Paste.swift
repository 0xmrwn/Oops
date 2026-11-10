import AppKit
import ApplicationServices
import OSLog
import OopsCore

extension EditorAccess {
    /// One span: select it, confirm the selection and its text, paste, confirm the text. `restoring`
    /// is the selection to put back if nothing was pasted (the first span only; later ones leave the caret).
    func paste(_ edit: TextChange, in snapshot: inout EditorSnapshot, over draft: String, giving next: String,
               restoring: NSRange?, weakly: inout Bool, clipboard: ClipboardLease, protected: () -> Bool) throws {
        let target = snapshot, element = snapshot.element, strategy = snapshot.strategy
        func putBack() {
            if let restoring, (try? assertTarget(target)) != nil,
               let value = text(element, strategy), reads(value, as: draft, target) {
                _ = select(element, restoring, strategy)
            }
        }
        guard protected() else { throw CorrectionError.message("The text-swap guard expired. Nothing replaced.") }
        func validate() throws {
            try Task.checkCancellation()
            guard protected() else { throw CorrectionError.message("The text-swap guard expired. Nothing replaced.") }
            try self.assertTarget(target)
            guard let text = self.text(element, strategy), self.reads(text, as: draft, target) else {
                throw CorrectionError.message("The draft changed while confirming selection. Nothing replaced.")
            }
        }
        var span = edit.range
        var nativeReplacement = false
        var input = edit.replacement, inputOriginal = edit.original
        let gecko = target.webContent && Self.isGecko(target)
        let marked = gecko && target.geckoMarkerSelection ? markerText(element).flatMap { MarkerOffsets.range(edit.range, from: draft, to: $0) } : nil
        let markerEdit = marked.map { TextChange(location: $0.location, original: edit.original, replacement: edit.replacement) }
        do {
            let word: Bool
            var ignoredMarkers = false
            if let markerEdit {
                do {
                    try SelectionConfirmation.require(markerEdit.range,
                        write: { selectGeckoWord(element, edit: markerEdit) },
                        read: { self.markerSelection(element) }, validate: validate)
                    // Gecko can acknowledge a document marker selection while a textarea keeps
                    // its own selection. Only use this path when the field and its copy agree too.
                    word = try selectedTextMatches(element, edit.original) != false
                        && editorHolds(edit.original, clipboard: clipboard,
                                       reselect: { _ = selectGeckoWord(element, edit: markerEdit) }, validate: validate)
                    ignoredMarkers = !word
                } catch is SelectionConfirmation.Failure {
                    word = false
                }
            } else { word = false }
            if ignoredMarkers { snapshot.geckoMarkerSelection = false }
            func selectSpan(_ range: NSRange) -> AXError {
                if word, range == edit.range, let markerEdit { return selectGeckoWord(element, edit: markerEdit) }
                return select(element, range, strategy)
            }
            if gecko, !word,
               try hidesEmptyLine(before: edit, in: draft, element: element, strategy: strategy, clipboard: clipboard, validate: validate) {
                throw CorrectionError.message("This editor may hide an empty line before this fix, so Oops can’t check the paste keeps it. Nothing replaced there.")
            }
            if !word {
                do {
                    let reads = try SelectionConfirmation.require(edit.range,
                        write: { selectSpan(edit.range) },
                        read: { self.selection(element, strategy) },
                        validate: validate)
                    if reads > 1 { Self.selectionLog.info("selection_confirmed_after_wait reads=\(reads, privacy: .public)") }
                } catch SelectionConfirmation.Failure.unconfirmed where strategy != .markers {
                    span = try nearby(edit, in: snapshot, validate: validate)
                }
            }
            // Marker offsets are the document's own: check they land on the text the edit replaces.
            if strategy == .markers, !sameText(markerString(element, edit.range) ?? "", edit.original) {
                throw CorrectionError.message("The editor’s text positions didn’t match its text. Nothing replaced.")
            }
            // The editor's own reading of its new selection must be the text this paste replaces: one
            // whose offsets drift around atoms selects something else, and pasting there would damage it.
            let ordered = target.webContent && (displayOrdered(element) || text(element, strategy).map { !sameDraft($0, draft) } == true)
            if strategy != .markers, selectedTextMatches(element, edit.original, at: edit.location) == false {
                guard !word else { throw Self.selectedDifferentText }
                do {
                    span = try aim(edit, in: snapshot, validate: validate)
                } catch let error as CorrectionError where error == Self.selectedDifferentText && ordered {
                    // Chromium reads the selected text of mixed-direction text out of its display order, so it
                    // can't confirm the selection, nor show where to aim it: the copy check below does.
                    Self.selectionLog.notice("selected_text_display_order")
                    span = edit.range
                    _ = select(element, span, strategy)
                }
            }
            // A paste replaces the editor's own selection. In web content that can differ from the DOM
            // selection Accessibility reads back (Monaco outside Chrome, an editor in a shadow root, Slate
            // until its throttled handler runs), so copying is the only way to see it. Native text views
            // report their own selection, and the copy would land in clipboard history, so they skip it.
            if target.webContent {
                var holds = try editorHolds(edit.original, clipboard: clipboard, reselect: { _ = selectSpan(span) },
                                            validate: validate)
                // In display order the aim can find the selected text a unit off by chance: the fix's own offsets then.
                if !holds, ordered, span != edit.range {
                    span = edit.range
                    holds = try editorHolds(edit.original, clipboard: clipboard, reselect: { _ = self.select(element, span, strategy) },
                                            validate: validate)
                    if holds { Self.selectionLog.notice("selected_text_display_order aim_undone") }
                }
                if !holds, provedWordMarkers(element, edit: edit, draft: draft) != nil { nativeReplacement = true }
                guard holds || nativeReplacement else { throw EditorKeptSelection() }
            }
            if gecko, !nativeReplacement,
               let inner = try interiorInput(edit, over: draft, in: snapshot, clipboard: clipboard, validate: validate) {
                input = inner.replacement
                inputOriginal = inner.original
                span = inner.range
            }
            // Web editors take typed and pasted text's formatting from the first character replaced: leave
            // out an untouched bold word at either end. Native ones get the formatting in the paste instead.
            if target.webContent, !gecko, !nativeReplacement, span == edit.range,
               let inner = try narrowed(edit, element: element, strategy: strategy, clipboard: clipboard, validate: validate,
                                        reselectWhole: { selectSpan(edit.range) }) {
                input = inner.replacement
                inputOriginal = inner.original
                span = inner.range
            }
            let rich = target.webContent || strategy != .value ? nil
                : richInput(element, span, original: inputOriginal, replacement: input)
            try clipboard.install(input, rtf: rich)
        } catch {
            if let failure = error as? SelectionConfirmation.Failure {
                Self.selectionLog.notice("\(failure.diagnostic, privacy: .public)")
            }
            let placementFailed = error is SelectionConfirmation.Failure || error is EditorKeptSelection
                || (error as? CorrectionError) == Self.selectedDifferentText
            // A native range replacement does not depend on the editor accepting a selection.
            // Its field-local word proof remains mandatory; draft/focus/clipboard failures never qualify.
            if target.webContent, placementFailed, provedWordMarkers(element, edit: edit, draft: draft) != nil {
                do {
                    try validate()
                    try clipboard.install(edit.replacement)
                    nativeReplacement = true
                } catch { putBack(); throw error }
            } else {
                // A failed/late action must not restore a stale selection into newer work.
                putBack()
                throw error
            }
        }
        // Paste uses each editor's own text-input/undo path, including multiline handling.
        // Never fall back to Select All, delete/retype, or raw HTML replacement.
        do {
            try assertTarget(target)
            try Task.checkCancellation()
            guard protected() else { throw CorrectionError.message("The text-swap guard expired. Nothing replaced.") }
            // A delayed selection acknowledgement must not extend our trust in
            // a clipboard entry that another app has replaced in the meantime.
            try clipboard.requireOwnership()
        } catch { putBack(); throw error }
        // A marker-bound native operation addresses its proved word directly, independent of an
        // editor's stale copy/paste selection. Never retry an operation whose result is unknown.
        if nativeReplacement {
            let range: CFTypeRef
            do {
                guard let proved = provedWordMarkers(element, edit: edit, draft: draft) else { throw Self.selectedDifferentText }
                range = proved
                try validate()
                try clipboard.requireOwnership()
            } catch { putBack(); throw error }
            let operation: [String: Any] = ["AXTextOperationMarkerRanges": [range], "AXTextOperationType": "TextOperationReplacePreserveCase",
                                            "AXTextOperationReplacementString": edit.replacement, "AXTextOperationSmartReplace": false]
            _ = parameterized(element, "AXTextOperation", operation as CFDictionary)
        } else {
            // Chromium can insert Unicode at a cached caret. Only probe for Chromium when the
            // replacement is web content with non-ASCII input that needs that distinction.
            let typed = target.webContent && (gecko || input.utf8.allSatisfy { $0 < 128 }
                || !Self.isChromiumHost(pid: target.pid, geometry: target.geometry)) && KeyboardGate.postText(input)
            if !typed { KeyboardGate.postCommand("v") }
        }
        // A word that occurs once in the draft can't have been pasted over elsewhere: a reading in display
        // order then confirms the paste wherever its runs moved. An interior edit needs its own
        // uniqueness proof; the whole word being unique says nothing about one changed letter.
        if confirm(&snapshot, holding: next, over: draft, pasted: NSRange(location: edit.location, length: edit.replacement.utf16.count),
                   distinct: { DisplayOrder.distinct([inputOriginal], in: draft) }, weakly: &weakly) {
            // Gecko updates its offsets after its text: the next span is selected once the caret shows at
            // the end of this paste (most editors put it there), or after 300 ms.
            let caret = NSRange(location: span.location + input.utf16.count, length: 0)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            while selection(snapshot.element, snapshot.strategy) != caret, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            return
        }
        try undoMisplaced(input, in: snapshot, over: draft, giving: next)
        if selection(element, strategy) == span { putBack() }
        var beside = false
        if let current = text(element, strategy) {
            let common = zip(current.utf16, next.utf16).prefix { $0 == $1 }.count
            beside = TextEdits.changedBeside(NSRange(location: edit.location, length: edit.replacement.utf16.count), current: current, expected: next)
            Self.selectionLog.notice("replacement_unconfirmed expected_len=\(next.utf16.count, privacy: .public) current_len=\(current.utf16.count, privacy: .public) common_prefix=\(common, privacy: .public) beside=\(beside, privacy: .public) selection=\(String(describing: self.selection(element, strategy)), privacy: .public)")
        }
        // Never blindly retry or roll back an editor whose response is unknown.
        throw UnconfirmedPaste(beside: beside)
    }
}
