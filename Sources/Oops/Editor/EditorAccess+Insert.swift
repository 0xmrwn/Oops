import AppKit
import ApplicationServices
import OSLog
import OopsCore

/// Writing new text at the caret, for a feature that has text of its own to put in (dictation). Unlike
/// a correction it needs no draft: the field may be empty or show only its placeholder. The text is
/// pasted through the editor's own input path, over the selection when there is one, spaced against the
/// text before the caret (Hex's rules, `InsertSpacing`), under dictation's application policy and Fix's
/// secret-field rules. A terminal takes it blind, on one line, and nothing presses Return.
extension EditorAccess {
    static let insertLog = Logger(subsystem: "dev.0xmrwn.oops", category: "Insert")

    /// The focused field as an insert found it. `before` is its text and selection when it can be
    /// read, which is what lets the paste be confirmed.
    private struct InsertTarget {
        let element: AXUIElement
        let pid: pid_t
        let hostPID: pid_t?
        let role: String
        let strategy: CaptureStrategy?
        let before: (text: String, selection: NSRange)?
        let placeholders: [String]
        /// Whether the app's accessibility switch was Oops's already, and so isn't this insert's to turn off.
        let heldSwitch: Bool
        /// A terminal: no text to read, so no spacing and no confirmation.
        let terminal: Bool
    }

    /// Writes `text` at the caret of the focused field, replacing its selection, and says whether it
    /// went in or why nothing was written.
    func insert(_ text: String) async -> InsertOutcome {
        let outcome: InsertOutcome
        do { outcome = try await write(text) }
        catch let refusal as InsertRefusal { outcome = .refused(refusal) }
        catch is CancellationError { outcome = .refused(.cancelled) }
        catch { outcome = .refused(.noEditor) }
        Self.insertLog.notice("insert length=\(text.utf16.count, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func write(_ text: String) async throws -> InsertOutcome {
        guard !text.isEmpty else { throw InsertRefusal.empty }
        guard AXIsProcessTrusted() else { throw InsertRefusal.permission }
        let target = try insertTarget()
        defer { if !target.heldSwitch { restoreFullAccessibility(pid: target.pid) } }
        // ⌘V with the shortcut's own modifiers still down would be another chord.
        do { try await KeyboardGate.waitForModifierRelease() }
        catch is CancellationError { throw CancellationError() }
        catch { throw InsertRefusal.keysHeld }
        let shaped = target.terminal ? TextInsertion.oneLine(text)
            : InsertSpacing.shaped(text, in: target.before?.text, selection: target.before?.selection, previous: lastInsert,
                                   placeholders: target.placeholders)
        let outcome = try paste(shaped, into: target)
        lastInsert = shaped
        return outcome
    }

    /// Hex's order (`PasteSequence`): save the clipboard, commit, write the text, ⌘V, schedule the
    /// clipboard's return, settle. Then the field is read back, where it can be.
    private func paste(_ text: String, into target: InsertTarget) throws -> InsertOutcome {
        let clipboard = insertClipboard
        var refusal = InsertRefusal.clipboard
        let generation: UInt64
        do {
            generation = try clipboard.paste(text) {
                // Waiting for the keys gave focus time to move: paste only into the field that was checked.
                if Task.isCancelled { refusal = .cancelled; return false }
                do { try assertStillFocused(target) } catch { refusal = error as? InsertRefusal ?? .focusMoved; return false }
                return true
            }
        } catch { throw refusal }
        try PasteSequence.complete(post: { KeyboardGate.postCommand("v") },
                                   scheduleRestore: { clipboard.scheduleRestore(generation) },
                                   wait: { Thread.sleep(forTimeInterval: Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) })
        guard let strategy = target.strategy, let before = target.before,
              let expected = TextInsertion.result(of: text, in: before.text, replacing: before.selection, placeholders: target.placeholders) else {
            return .unconfirmed
        }
        // Most editors show the paste within the settle; a slow one gets a moment more.
        for attempt in 0..<16 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.025) }
            if let now = self.text(target.element, strategy), sameText(now, expected) { return .inserted }
        }
        return .unconfirmed
    }

    /// The field that was checked still has focus. One that can be read compares equal across reads, so
    /// nothing stands in for it: its window holds other fields of its role, a password field among them.
    /// An editor that exposes nothing may come back as another element, which is checked for a secret again.
    private func assertStillFocused(_ target: InsertTarget) throws {
        guard target.strategy == nil else {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.hostPID ?? target.pid,
                  let front = try? focused(), pid(of: front) == target.pid,
                  CFEqual(front, target.element) || caretHolder(front).map({ CFEqual($0, target.element) }) == true
            else { throw InsertRefusal.focusMoved }
            return
        }
        do { try assertFocus(element: target.element, pid: target.pid, hostPID: target.hostPID, role: target.role) }
        catch { throw InsertRefusal.focusMoved }
        guard let front = try? focused() else { throw InsertRefusal.focusMoved }
        let field = CFEqual(front, target.element) ? front : caretHolder(front) ?? front
        guard !TextInsertion.holdsSecret(role: target.role, subrole: attribute(field, kAXSubroleAttribute) as? String,
                                         descriptions: descriptions(field), value: nil, readable: false)
        else { throw InsertRefusal.secureField }
    }

    /// The focused field, once the app and the field pass the rules a draft is read under.
    private func insertTarget() throws -> InsertTarget {
        var element: AXUIElement
        do { element = try focusedWaking() } catch is CancellationError { throw CancellationError() } catch { throw InsertRefusal.noEditor }
        let pid = self.pid(of: element)
        guard let scope = scope(of: pid, for: .dictate) else { throw InsertRefusal.noEditor }
        if let refusal = TextInsertion.refusal(for: scope.verdict) { throw refusal }
        guard case .accepted(let owner, let nested) = scope.verdict else { throw InsertRefusal.noEditor }
        let heldSwitch = switches.attribute(for: pid) != nil
        var kept = false
        defer { if !kept, !heldSwitch { restoreFullAccessibility(pid: pid) } }
        // A terminal shows no text to read: there is nothing to wake, and its prompt takes a paste whatever it exposes.
        let terminal = EditorApplicationPolicy.terminals.contains(owner)
        let woken = terminal ? (field: nil, awakeDocument: false) : try wakingField(&element, pid: pid)
        let role = woken.field?.role ?? attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = woken.field?.subrole ?? attribute(element, kAXSubroleAttribute) as? String
        let webContent = isWebContent(element)
        if woken.field == nil, !terminal {
            // An editor that exposes no text takes a paste all the same, but only where text could go:
            // never a list, a table or the Finder, where ⌘V pastes files or rows.
            guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXWebArea", kAXGroupRole, kAXUnknownRole].contains(role)
                || role == kAXStaticTextRole && webContent, owner != "com.apple.finder" else { throw InsertRefusal.noEditor }
        }
        let strategy: CaptureStrategy? = terminal ? nil : woken.field != nil ? .value : woken.awakeDocument || supportsMarkers(element) ? .markers : nil
        let value = woken.field != nil && subrole != kAXSecureTextFieldSubrole ? self.text(element, .value) : nil
        guard !TextInsertion.holdsSecret(role: role, subrole: subrole, descriptions: descriptions(element), value: value,
                                         readable: woken.field != nil) else { throw InsertRefusal.secureField }
        // Pasting under marked text breaks the composition.
        if composing(element) { throw InsertRefusal.composing }
        if strategy == .value, readOnly(element, webContent: webContent) { throw InsertRefusal.readOnly }
        // A hidden input proxy's value is only the selection, not the text on screen: nothing to confirm against.
        let readable = strategy.flatMap { $0 == .value && isInputProxy(element) ? nil : $0 }
        let before = readable.flatMap { strategy in
            self.text(element, strategy).flatMap { text in self.selection(element, strategy).map { (text, $0) } }
        }
        kept = true
        return InsertTarget(element: element, pid: pid, hostPID: nested ? scope.foreground?.processIdentifier : nil, role: role,
                            strategy: readable, before: before,
                            placeholders: [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute]
                                .compactMap { attribute(element, $0) as? String },
                            heldSwitch: heldSwitch, terminal: terminal)
    }
}
