import AppKit
import ApplicationServices
import OSLog
import OopsCore

/// How the draft was read: the editor's own text and selection; its text markers' text with its
/// character ranges, when its value miscounts its atoms (an image or chip the ranges count as one
/// character, spelled out or left out of the value); a document's text markers (WebKit and Chromium
/// documents with no plain value, like Mail's body); or, when it exposes neither, the selection copied with ⌘C.
enum CaptureStrategy: String { case value = "ax-value", atoms = "ax-atoms", markers = "ax-markers", copy }

/// An immutable reference to an element in some app, which the Accessibility API takes from any
/// thread: Oops reads through it on its Accessibility queue and keeps it on the main actor.
extension AXUIElement: @retroactive @unchecked Sendable {}

/// An editor read fine, with nothing in it: the drop says so where the editor is.
struct EmptyDraft: Error {
    let geometry: CapsulePlacement.Geometry
    /// What else to say: a field with no value may belong to an editor that keeps its text to itself.
    var detail = ""
    static let unread = "If your draft is there, select it first."
}

/// A focused editor that exposes no text or selection, or only a hidden input proxy's: only a copied
/// selection can reach it. The editor as captured comes along, to check focus is still there before copying.
struct OpaqueEditor: Error {
    let element: AXUIElement
    let pid: pid_t
    let hostPID: pid_t?
    let role: String
    /// False when the editor is known to hold no selection, so there is nothing to copy.
    let selected: Bool?
    /// What to report when nothing is copied: the editor's value was empty, so its draft probably is.
    let empty: EmptyDraft?
    var rejectCopiedLine = false
    let snapshot: @Sendable (TextTransaction) -> EditorSnapshot
}

struct EditorSnapshot {
    /// The editor read, or the element that replaced it when the app remounted it after an edit.
    var element: AXUIElement
    let pid: pid_t
    let hostPID: pid_t?
    let appName: String
    let bundleID: String?
    /// The app as Settings names it: the frontmost app for a helper nested in it.
    let owner: String
    let appVersion: String?
    let role: String
    let subrole: String?
    /// What was read; moved onto the draft as the editor reports it again, if that differs away from the fixes.
    var transaction: TextTransaction
    let geometry: CapsulePlacement.Geometry
    var strategy = CaptureStrategy.value
    /// Inside a web page, where an editor may keep a selection of its own: each paste is checked by copying.
    var webContent = false
    /// Some Gecko inputs acknowledge document marker selections but keep their own selection.
    /// Once proved here, avoid that failed probe on later words and restore of this same draft.
    var geckoMarkerSelection = true
    /// How far the draft's selection sits from the range the editor reported for it, and how much longer it is.
    var rangeShift = 0, rangeLengthShift = 0
    /// The web page's address at capture, nil outside one.
    var page: String?
    /// The editor's window, to recognise the editor if the app remounts it.
    var window: AXUIElement?
}

/// No keystroke tracking during inference. AX calls run on one bounded worker queue, this actor's
/// executor, one operation at a time. The primitives (attributes, ranges, geometry) hold no state and
/// are nonisolated, for Debug probes on their own queue.
actor EditorAccess {
    let queue = DispatchSerialQueue(label: "oops.Accessibility", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    static let selectionLog = Logger(subsystem: "dev.0xmrwn.oops", category: "Selection")
    static let captureLog = Logger(subsystem: "dev.0xmrwn.oops", category: "Capture")
    /// The Chromium accessibility switch set on each host, to restore the same one.
    let switches = AccessibilitySwitches()
    /// Processes already checked for Gecko (and woken if so).
    var geckoChecked: Set<pid_t> = []
    /// The clipboard inserts go through, kept between them: rapid inserts give back what was there before the first.
    let insertClipboard = InsertClipboard()
    init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            Task { await self?.wakeGecko(pid) }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { Task { await self.wakeGecko(pid) } }
    }

    func capture() throws -> EditorSnapshot {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw CorrectionError.message("Allow Oops in \(AccessibilityPermission.paneName) first.") }
        var element = try self.focusedWaking()
        let pid = self.pid(of: element)
        guard let scope = self.scope(of: pid) else { throw CorrectionError.message("No editable composer has focus.") }
        let app = scope.app, foreground = scope.foreground, name = scope.name
        let nested: Bool, owner: String
        switch scope.verdict {
        case .accepted(let id, let isNested): owner = id; nested = isNested
        case .denied: throw CorrectionError.message("Oops stays out of terminals and password managers.")
        case .turnedOff: throw CorrectionError.message("Oops is off in \(name). Turn it back on in Settings.")
        case .unknown: throw CorrectionError.message("No editable composer has focus.")
        }
        let hostPID = nested ? foreground?.processIdentifier : nil
        let woken = try self.wakingField(&element, pid: pid), awakeDocument = woken.awakeDocument
        var field = woken.field
        let version = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        /// The editor as only copy and paste can reach it: `selected` is false when it is known to hold no selection.
        func opaque(role: String, subrole: String?, selected: Bool?, empty: EmptyDraft? = nil, rejectCopiedLine: Bool = false) -> OpaqueEditor {
            let geometry = self.geometry(element), target = element, bundleID = app.bundleIdentifier
            return OpaqueEditor(element: target, pid: pid, hostPID: hostPID, role: role, selected: selected, empty: empty, rejectCopiedLine: rejectCopiedLine) { transaction in
                EditorSnapshot(element: target, pid: pid, hostPID: hostPID, appName: name, bundleID: bundleID,
                               owner: owner, appVersion: version, role: role, subrole: subrole, transaction: transaction,
                               geometry: geometry, strategy: .copy)
            }
        }
        var strategy = CaptureStrategy.value
        if field == nil, awakeDocument || self.supportsMarkers(element) {
            strategy = .markers
            field = (self.attribute(element, kAXRoleAttribute) as? String ?? "", self.attribute(element, kAXSubroleAttribute) as? String)
        }
        guard let field else {
            let role = self.attribute(element, kAXRoleAttribute) as? String ?? ""
            let subrole = self.attribute(element, kAXSubroleAttribute) as? String
            // Only where text could be selected: never a list, table or the Finder, where ⌘C
            // copies files or rows.
            // Static text too inside a web page: focus there can sit on text the editor points at.
            guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXWebArea", kAXGroupRole, kAXUnknownRole].contains(role)
                || role == kAXStaticTextRole && self.isWebContent(element),
                  owner != "com.apple.finder" else {
                throw CorrectionError.message("Place the cursor in the message composer, then press the shortcut.")
            }
            // The copy fallback reads whatever is selected: never in a field that holds a secret.
            guard subrole != kAXSecureTextFieldSubrole, !SensitiveField.matches(self.descriptions(element)) else {
                throw CorrectionError.message("Oops doesn’t read password or code fields.")
            }
            self.logOpaque(element, role: role)
            throw opaque(role: role, subrole: subrole, selected: nil)
        }
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard field.subrole != kAXSecureTextFieldSubrole, field.role == kAXTextAreaRole || !SensitiveField.matches(self.descriptions(element)) else {
            self.restoreFullAccessibility(pid: pid)
            throw CorrectionError.message("Oops doesn’t read password or code fields.")
        }
        guard var value = self.text(element, strategy), var selection = self.selection(element, strategy) else {
            self.restoreFullAccessibility(pid: pid)
            throw CorrectionError.message("This composer does not expose reliable text and selection ranges yet. Nothing replaced.")
        }
        if strategy == .value, let consistent = self.consistentStrategy(element, value: value, selection: selection),
           let text = self.text(element, consistent), let range = self.selection(element, consistent) {
            strategy = consistent; value = text; selection = range
        }
        self.logField(element, role: field.role, strategy: strategy, value: value, selection: selection)
        let webArea = self.webArea(of: element), webContent = webArea != nil
        if let refusal = self.refusal(element, field: field, strategy: strategy, value: value, webContent: webContent) {
            self.restoreFullAccessibility(pid: pid)
            throw refusal
        }
        if strategy == .value, self.isInputProxy(element) {
            self.restoreFullAccessibility(pid: pid)
            throw opaque(role: field.role, subrole: field.subrole, selected: selection.length > 0 ? true : nil, rejectCopiedLine: true)
        }
        // An empty value may be an editor that keeps its text to itself (a painted code editor's empty
        // input in a web page): a selection there can still be copied. Nothing copied, or outside web
        // content, the draft is empty or can't be read: say both.
        if value.isEmpty {
            self.restoreFullAccessibility(pid: pid)
            let empty = EmptyDraft(geometry: self.geometry(element), detail: EmptyDraft.unread)
            guard webContent else { throw empty }
            throw opaque(role: field.role, subrole: field.subrole, selected: nil, empty: empty)
        }
        if CorrectionPolicy.isPlaceholder(value, hints: [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute]
            .compactMap { self.attribute(element, $0) as? String }) {
            self.restoreFullAccessibility(pid: pid)
            throw EmptyDraft(geometry: self.geometry(element))
        }
        // A selection whose text sits a few units off in the value (ranges that count an atom differently):
        // the draft's selection is where that text really is.
        var shift = 0, lengthShift = 0
        if selection.length > 0, let selected = self.attribute(element, kAXSelectedTextAttribute) as? String, !selected.isEmpty,
           NSMaxRange(selection) <= value.utf16.count,
           !sameText(Self.visible(selected), Self.visible((value as NSString).substring(with: selection))),
           let found = TextOffsets.nearest(selected, in: value, to: selection.location, within: 8) {
            shift = found - selection.location; lengthShift = selected.utf16.count - selection.length
            selection = NSRange(location: found, length: selected.utf16.count)
        }
        let transaction: TextTransaction
        do {
            transaction = try TextTransaction(value: value, selection: selection, selectedText: strategy == .value
                                              ? self.attribute(element, kAXSelectedTextAttribute) as? String : nil)
            // The selected text spells atoms the way the value does: the same text around them.
            if strategy == .atoms, selection.length > 0, let selected = self.attribute(element, kAXSelectedTextAttribute) as? String,
               !sameText(selected, transaction.source), TextEdits.atomSpelling(value: selected, markers: transaction.source) == nil {
                throw CorrectionError.message("The editor’s selection does not match its text. Nothing replaced.")
            }
        } catch {
            self.restoreFullAccessibility(pid: pid)
            if (error as? CorrectionError)?.reason == .empty { throw EmptyDraft(geometry: self.geometry(element)) }
            throw error
        }
        return EditorSnapshot(element: element, pid: pid, hostPID: hostPID, appName: name,
                              bundleID: app.bundleIdentifier, owner: owner, appVersion: version, role: field.role, subrole: field.subrole,
                              transaction: transaction, geometry: self.geometry(element), strategy: strategy, webContent: webContent,
                              rangeShift: shift, rangeLengthShift: lengthShift, page: webArea.flatMap(self.page(of:)),
                              window: self.attribute(element, kAXWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil })
    }

    /// What a field says it is for: labels, placeholder, help, identifiers and autofill hints.
    func descriptions(_ element: AXUIElement) -> [String] {
        var texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXIdentifierAttribute,
                     "AXDOMIdentifier", "AXAutocompleteValue", "AXInputType"]
            .compactMap { attribute(element, $0) as? String }
        texts += (attribute(element, "AXDOMClassList") as? [String]) ?? []
        if let title = attribute(element, kAXTitleUIElementAttribute), CFGetTypeID(title) == AXUIElementGetTypeID() {
            let label = title as! AXUIElement
            texts += [kAXValueAttribute, kAXTitleAttribute].compactMap { attribute(label, $0) as? String }
        }
        return texts
    }

    /// Fresh capsule geometry for a captured editor, e.g. after the replacement reflowed it.
    func geometry(of element: AXUIElement) -> CapsulePlacement.Geometry? {
        guard !Task.isCancelled else { return nil }
        return geometry(element)
    }
    /// Whether the draft's window is still the one in front: its app is frontmost and, when the app
    /// says, the window holding the draft is its focused one. Unknown counts as in front.
    func isInFront(_ snapshot: EditorSnapshot) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.hostPID ?? snapshot.pid else { return false }
        let app = AXUIElementCreateApplication(snapshot.pid)
        guard let focused = attribute(app, kAXFocusedWindowAttribute), let own = attribute(snapshot.element, kAXWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(), CFGetTypeID(own) == AXUIElementGetTypeID() else { return true }
        return CFEqual(focused, own)
    }
    /// Geometry of whatever editor has focus, without reading its text (Diagnostics preview).
    func focusedGeometry() throws -> CapsulePlacement.Geometry {
        guard AXIsProcessTrusted() else { throw CorrectionError.message("Allow Oops in \(AccessibilityPermission.paneName) first.") }
        return self.geometry(try self.focusedWaking())
    }

    /// Waits up to `timeout` for Accessibility work already queued, so quitting doesn't race a
    /// switch being set.
    nonisolated func settle(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }
}
