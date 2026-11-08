import AppKit
import ApplicationServices
import OSLog
import OopsCore

/// Where corrected words sit on screen, for the in-place flash.
extension EditorAccess {
    /// Chromium lays out its accessibility tree without text geometry (and, while dormant, without
    /// text at all) until a screen reader is detected, and answers range bounds with placeholders
    /// until then. While a correction runs, set the host's switch for it: Electron apps take
    /// `AXManualAccessibility` (Claude; its set succeeds but reads back false); Chrome and WebView2
    /// take `AXEnhancedUserInterface`, the one VoiceOver sets, after a 2 s debounce that the provider
    /// call covers (Chrome answers "not implemented" and applies it: read it back). Tried in that
    /// order unless `HighlightAccessibility` (debug default) forces `off`, `manual` or `enhanced`.
    /// Capture may already have set it to read a dormant editor. Returns whether Oops holds a switch
    /// on the host, so it can be restored.
    func enableFullAccessibility(for snapshot: EditorSnapshot) -> Bool {
        guard Self.accessibilitySwitch != "off", snapshot.pid != getpid() else { return false }
        return switches.attribute(for: snapshot.pid) != nil || setFullAccessibility(pid: snapshot.pid, geometry: snapshot.geometry)
    }
    func disableFullAccessibility(for snapshot: EditorSnapshot) {
        restoreFullAccessibility(pid: snapshot.pid)
    }
    /// Whether the editor is still in the page it was read in: after a reload or a navigation there is
    /// nothing left to place, and a switch held for it would carry over to the next page's capture.
    func isOnItsPage(_ snapshot: EditorSnapshot) -> Bool {
        guard let page = snapshot.page else { return true }
        return webArea(of: snapshot.element).flatMap(self.page(of:)) == page
    }
    /// Sets the switch on a Chromium host, on the Accessibility queue; false when it isn't one, the
    /// switch was already on (someone else's), or it wouldn't take.
    nonisolated func setFullAccessibility(pid: pid_t, geometry: CapsulePlacement.Geometry) -> Bool {
        guard Self.accessibilitySwitch != "off", pid != getpid() else { return false }
        // Chromium hosts only: AppKit answers AXEnhancedUserInterface too, but there it changes
        // window animations (the yabai/Rectangle issue) and buys nothing.
        guard Self.isChromiumHost(pid: pid, geometry: geometry) else {
            Self.highlightLog.info("accessibility_switch skipped=not_chromium"); return false
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let candidates = Self.accessibilitySwitch.map { [$0] } ?? ["AXManualAccessibility", "AXEnhancedUserInterface"]
        for attribute in candidates {
            guard (self.attribute(app, attribute) as? NSNumber)?.boolValue != true else {
                Self.highlightLog.info("accessibility_switch attribute=\(attribute, privacy: .public) skipped=already_on"); return false
            }
            // Recorded first: quitting or crashing between the set and its record would leave it on.
            switches.record(attribute, pid: pid)
            let set = AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
            let applied = (self.attribute(app, attribute) as? NSNumber)?.boolValue == true
            Self.highlightLog.info("accessibility_switch attribute=\(attribute, privacy: .public) result=\(set.rawValue, privacy: .public) applied=\(applied, privacy: .public)")
            if set == .success || applied { return true }
            _ = switches.take(pid)
        }
        return false
    }
    /// Turns off the switch Oops set on `pid`, if any. Forgotten only once turned off, so a quit in
    /// between still restores it.
    nonisolated func restoreFullAccessibility(pid: pid_t) {
        guard let attribute = switches.attribute(for: pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanFalse)
        _ = switches.take(pid)
    }
    /// Chrome, Edge WebView2 and Electron ship their engine as a framework or helper named for it,
    /// or (Codex) renamed but still carrying Chromium's resources; and whatever the bundle says,
    /// a 0×0 caret rect is Chromium's placeholder (AppKit's zero-length caret is zero wide but has a height).
    static func isChromiumHost(pid: pid_t, geometry: CapsulePlacement.Geometry) -> Bool {
        let placeholder = [geometry.caret, geometry.previousCharacter].contains { $0.map { $0.width == 0 && $0.height == 0 } ?? false }
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return placeholder }
        let contents = bundle.appendingPathComponent("Contents"), fm = FileManager.default
        let names = ["Frameworks", "Helpers"].flatMap { (try? fm.contentsOfDirectory(atPath: contents.appendingPathComponent($0).path)) ?? [] }
        if names.contains(where: { name in ["Chrome", "Chromium", "Electron", "Edge", "WebView"].contains { name.localizedCaseInsensitiveContains($0) } }) { return true }
        let frameworks = contents.appendingPathComponent("Frameworks")
        for name in names where name.hasSuffix(".framework") {
            let resources = frameworks.appendingPathComponent(name).appendingPathComponent("Resources").resolvingSymlinksInPath()
            if fm.fileExists(atPath: resources.appendingPathComponent("chrome_100_percent.pak").path) { return true }
        }
        return placeholder
    }
    static var accessibilitySwitch: String? {
        switch DebugFlags.highlightAccessibility {
        case "manual": "AXManualAccessibility"
        case "enhanced": "AXEnhancedUserInterface"
        case "off": "off"
        default: nil
        }
    }
    static let highlightLog = Logger(subsystem: "dev.0xmrwn.oops", category: "Highlight")

    /// Screen rects (AX coordinates) where the draft shows the given UTF-16 ranges of its full
    /// value: one per line a range covers, from the editor's own layout through Accessibility.
    /// An empty range (a pure deletion) becomes a slim marker after the character before it.
    /// Ranges the editor cannot place are skipped; placeholders (Chromium's zero-size or
    /// off-element rects) count as unplaceable.
    func highlightRects(for ranges: [NSRange], in snapshot: EditorSnapshot, quiet: Bool = false) -> [CGRect] {
        highlightPlacement(for: ranges, in: snapshot, quiet: quiet).rects
    }

    /// The rects, and how many of the measured ranges (at most 40) got none.
    func highlightPlacement(for ranges: [NSRange], in snapshot: EditorSnapshot, quiet: Bool = false) -> (rects: [CGRect], missing: Int) {
        let element = snapshot.element
        guard let box = self.frame(element) else { return ([], min(ranges.count, 40)) }
        // A word's rect lies inside the editor; Chromium's placeholders are zero-size, whole-page, or the
        // editor's own frame (its text-marker bounds for a word in a contenteditable), which would light
        // up the whole draft.
        let valid = box.insetBy(dx: -4, dy: -4)
        func usable(_ rect: CGRect?) -> CGRect? {
            guard let rect, rect.width > 0, rect.height > 0, rect.height <= 200, valid.contains(rect) else { return nil }
            let wholeField = abs(rect.width - box.width) < 2 && abs(rect.height - box.height) < 2
            return wholeField ? nil : rect
        }
        // Chromium answers range bounds only on text leaves and native text fields, never on a
        // contenteditable root: map the draft's offsets onto the root's static-text descendants.
        var leaves: [(element: AXUIElement, range: NSRange)]?
        func leafBounds(_ range: NSRange) -> CGRect? {
            if leaves == nil { leaves = self.textLeaves(of: element, length: (self.attribute(element, kAXValueAttribute) as? String)?.utf16.count ?? 0, quiet: quiet) }
            guard let leaves, !leaves.isEmpty else { return nil }
            let parts = leaves.compactMap { leaf -> CGRect? in
                let part = NSIntersectionRange(leaf.range, range)
                guard part.length > 0 else { return nil }
                return usable(self.rangeRect(leaf.element, NSRange(location: part.location - leaf.range.location, length: part.length)))
            }
            return parts.isEmpty ? nil : parts.dropFirst().reduce(parts[0]) { $0.union($1) }
        }
        // Read through text markers with the character ranges, the ranges sit a unit or two off the text
        // around atoms: find the range whose own text is the word, as the swap aimed its selection.
        let atoms = snapshot.strategy == .atoms ? self.text(element, .atoms) as NSString? : nil
        func aligned(_ range: NSRange) -> CGRect? {
            guard let atoms, NSMaxRange(range) <= atoms.length else { return nil }
            let word = atoms.substring(with: range)
            for shift in [0, 1, 2, -1, 3, -2, 4] {
                guard let shifted = TextOffsets.plausible(location: range.location + shift, length: range.length),
                      let found = self.rangeString(element, shifted), sameText(found, word) else { continue }
                return usable(self.rangeRect(element, shifted))
            }
            return nil
        }
        // When the leaves don't add up to the draft (images and chips between them), find the word in
        // their text near where it should be.
        var joined: (text: String, leaves: [(element: AXUIElement, range: NSRange)])?
        func searchedBounds(_ range: NSRange) -> CGRect? {
            guard range.length > 0, let model = self.text(element, snapshot.strategy) as NSString?, NSMaxRange(range) <= model.length else { return nil }
            if joined == nil {
                var offset = 0, text = ""
                let leaves = self.leafTexts(of: element).map { leaf -> (element: AXUIElement, range: NSRange) in
                    defer { offset += leaf.text.utf16.count; text += leaf.text }
                    return (leaf.element, NSRange(location: offset, length: leaf.text.utf16.count))
                }
                joined = (text, leaves)
            }
            guard let joined, let at = TextOffsets.nearest(model.substring(with: range), in: joined.text, to: range.location, within: 32),
                  let leaf = joined.leaves.first(where: { NSLocationInRange(at, $0.range) && NSMaxRange($0.range) >= at + range.length })
            else { return nil }
            return usable(self.rangeRect(leaf.element, NSRange(location: at - leaf.range.location, length: range.length)))
        }
        var route = ""
        func bounds(_ range: NSRange) -> CGRect? {
            if let rect = aligned(range) { route = "aligned"; return rect }
            if let rect = usable(self.rangeRect(element, range)) { route = "range"; return rect }
            if let rect = usable(self.markerRect(element, range)) { route = "marker"; return rect }
            if let rect = leafBounds(range) { route = "leaves"; return rect }
            route = "search"
            return searchedBounds(range)
        }
        var lineHeight: CGFloat?
        func place(_ range: NSRange) -> [CGRect]? {
            if range.length == 0 {
                guard range.location > 0, let previous = bounds(NSRange(location: range.location - 1, length: 1)) else { return nil }
                return [CGRect(x: previous.maxX - 1.5, y: previous.minY, width: 3, height: previous.height)]
            }
            guard let whole = bounds(range) else { return nil }
            if lineHeight == nil, let first = bounds(NSRange(location: range.location, length: 1)) { lineHeight = first.height }
            // A range that wraps answers with its bounding box: split it along the editor's lines.
            guard let lineHeight, whole.height > lineHeight * 1.6 else { return [whole] }
            var index = range.location, segments: [CGRect] = []
            while index < NSMaxRange(range), segments.count < 12,
                  let line = self.parameterized(element, kAXLineForIndexParameterizedAttribute, index as CFNumber) as? NSNumber,
                  let lineRange = self.lineRange(element, line) {
                let part = NSIntersectionRange(lineRange, range)
                guard part.length > 0, NSMaxRange(lineRange) > index else { break }
                if let rect = bounds(part) { segments.append(rect) }
                index = NSMaxRange(lineRange)
            }
            return segments.isEmpty ? [whole] : segments
        }
        var rects: [CGRect] = [], missed: [NSRange] = []
        let started = CFAbsoluteTimeGetCurrent()
        for range in ranges.prefix(40) {
            guard !Task.isCancelled else { return ([], min(ranges.count, 40)) }
            let placed = place(range)
            if let placed { rects += placed } else { missed.append(range) }
            #if DEBUG
            // What each word got and from where, against the field, for the bake-off's highlight stage.
            if !quiet {
                let sizes = (placed ?? []).map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: ",")
                Self.highlightLog.info("highlight_range length=\(range.length, privacy: .public) route=\(route, privacy: .public) rects=\(sizes, privacy: .public) field=\(Int(box.width), privacy: .public)x\(Int(box.height), privacy: .public)")
            }
            #endif
        }
        // Gecko fills its text-bounds cache on the first request and answers that one with a zero
        // rect: ask once more for what it couldn't place.
        if !missed.isEmpty {
            Thread.sleep(forTimeInterval: 0.15)
            missed = missed.filter { range in
                guard !Task.isCancelled, let placed = place(range) else { return true }
                rects += placed
                return false
            }
        }
        // Only what shows: a word scrolled partly out of a small composer flashes where it shows.
        var visible = box, node = element
        for _ in 0..<4 {
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = parent as! AXUIElement
            if attribute(node, kAXRoleAttribute) as? String == kAXScrollAreaRole, let frame = frame(node) { visible = visible.intersection(frame); break }
        }
        rects = rects.map { $0.intersection(visible) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        if !quiet { Self.highlightLog.info("highlight_rects ranges=\(ranges.count, privacy: .public) rects=\(rects.count, privacy: .public) ms=\(Int(ms), privacy: .public)") }
        return (rects, missed.count)
    }
    /// The static-text descendants of a web editor with the draft offsets each covers. Blocks join
    /// with one newline in the draft; when the lengths add up neither way, the mapping is unknown.
    /// The element's static-text descendants in reading order, with their text.
    nonisolated func leafTexts(of element: AXUIElement) -> [(element: AXUIElement, text: String)] {
        var pending = [element], found: [(AXUIElement, String)] = [], visited = 0
        while let node = pending.popLast(), visited < 300 {
            visited += 1
            if attribute(node, kAXRoleAttribute) as? String == kAXStaticTextRole {
                found.append((node, attribute(node, kAXValueAttribute) as? String ?? "")); continue
            }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children.reversed()) }
        }
        return found
    }

    nonisolated func textLeaves(of element: AXUIElement, length: Int, quiet: Bool = false) -> [(element: AXUIElement, range: NSRange)] {
        let found = leafTexts(of: element).map { ($0.element, $0.text.utf16.count) }
        let sum = found.reduce(0) { $0 + $1.1 }
        let separator = sum == length ? 0 : (sum + max(found.count - 1, 0) == length ? 1 : -1)
        if !quiet { Self.highlightLog.info("text_leaves count=\(found.count, privacy: .public) sum=\(sum, privacy: .public) draft=\(length, privacy: .public) separator=\(separator, privacy: .public)") }
        guard separator >= 0 else { return [] }
        var offset = 0
        return found.map { leaf in
            defer { offset += leaf.1 + separator }
            return (leaf.0, NSRange(location: offset, length: leaf.1))
        }
    }
    nonisolated func lineRange(_ element: AXUIElement, _ line: NSNumber) -> NSRange? {
        guard let value = parameterized(element, kAXRangeForLineParameterizedAttribute, line), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(); guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    /// WebKit's path (Chromium answers it too once its tree is complete): index → marker, two
    /// markers → marker range, marker range → bounds.
    nonisolated func markerRect(_ element: AXUIElement, _ range: NSRange) -> CGRect? {
        markerRange(element, range).flatMap { parameterizedRect(element, "AXBoundsForTextMarkerRange", $0) }
    }
    nonisolated func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        AccessibilityExecution.perform(for: element) {
            var value: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
        }
    }
}
