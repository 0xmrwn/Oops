import AppKit
import ApplicationServices
import OopsCore

/// Sampling, off the main thread: Accessibility calls are IPC into the target app.
extension PlacementProbe {
    @concurrent static func sample(mode: Mode) async -> sending [String: Any] {
        var out: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "mode": mode.rawValue]
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        let front = NSWorkspace.shared.frontmostApplication
        out["frontmost"] = front?.bundleIdentifier
        var lookup: [String: Any] = [:]
        guard var element = focused(system, front, &lookup) else {
            out["lookup"] = lookup
            out["error"] = "No focused element. Click into a composer during the countdown."; return out
        }
        out["lookup"] = lookup
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid)
        out["bundle"] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let app = AXUIElementCreateApplication(pid)
        var restore: CFTypeRef?
        if let attribute = mode.attribute {
            // Chromium debounces either switch by ~2 s before the tree is complete.
            restore = raw(app, attribute) ?? kCFBooleanFalse
            out["accessibility_switch_set"] = AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue).rawValue
            try? await Task.sleep(for: .seconds(2.5))
            var again: [String: Any] = [:]
            if let refreshed = focused(system, front, &again) { element = refreshed }
        }
        defer { if let restore, let attribute = mode.attribute { AXUIElementSetAttributeValue(app, attribute as CFString, restore) } }
        out["app_flags"] = ["manual": describe(raw(app, "AXManualAccessibility")), "enhanced": describe(raw(app, "AXEnhancedUserInterface"))]

        let names: CFArray? = AccessibilityExecution.perform(for: element) {
            var names: CFArray?; AXUIElementCopyParameterizedAttributeNames(element, &names); return names
        }
        out["element"] = [
            "role": raw(element, kAXRoleAttribute) as? String ?? "", "subrole": raw(element, kAXSubroleAttribute) as? String ?? "",
            "frame": frame(element).map(json) as Any, "parameterized": (names as? [String]) ?? []
        ]
        var ancestors: [[String: Any]] = [], node = element
        for _ in 0..<6 {
            guard let parent = child(node, kAXParentAttribute) else { break }
            ancestors.append(["role": raw(parent, kAXRoleAttribute) as? String ?? "", "frame": frame(parent).map(json) as Any])
            node = parent
        }
        out["ancestors"] = ancestors
        out["ax_window"] = child(element, kAXWindowAttribute).flatMap(frame).map(json)
        // Window bounds and z-order without titles (titles would need Screen Recording).
        let owners = Set([pid, front?.processIdentifier ?? pid])
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { owners.contains(($0[kCGWindowOwnerPID as String] as? pid_t) ?? -1) && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as! CFDictionary?).flatMap { CGRect(dictionaryRepresentation: $0) }.map(json) }
        out["cg_windows"] = windows

        let selection = range(element)
        out["selection"] = selection.map { [$0.location, $0.length] }
        out["characters"] = (raw(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
            ?? (raw(element, kAXValueAttribute) as? String)?.utf16.count
        out["visible_range"] = value(element, kAXVisibleCharacterRangeAttribute).flatMap(cfRange).map { [$0.location, $0.length] }
        out["insertion_line"] = (raw(element, kAXInsertionPointLineNumberAttribute) as? NSNumber)?.intValue
        out["caret"] = caret(element, selection)
        try? await Task.sleep(for: .milliseconds(20))
        out["caret_repeat"] = caret(element, selection) // Stability: some engines briefly report stale rects.
        out["words"] = words(element)
        out["leaves"] = leaves(element)
        return out
    }

    /// Chromium answers `AXBoundsForRange` only on text leaves and native text fields, never on a
    /// contenteditable root: list the root's static-text descendants (count, length and whether the
    /// first leaf's first word has a rect), to map draft offsets onto leaves.
    private nonisolated static func leaves(_ element: AXUIElement) -> [String: Any] {
        var pending = [element], found: [AXUIElement] = [], visited = 0, roles: [String: Int] = [:]
        while let node = pending.popLast(), visited < 300 {
            visited += 1
            let role = raw(node, kAXRoleAttribute) as? String ?? "none"
            roles[role, default: 0] += 1
            if role == kAXStaticTextRole { found.append(node); continue }
            if let children = raw(node, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children.reversed()) }
        }
        var out: [String: Any] = ["count": found.count, "visited": visited, "roles": roles]
        out["lengths"] = found.prefix(40).map { (raw($0, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? ((raw($0, kAXValueAttribute) as? String)?.utf16.count ?? -1) }
        if let first = found.first, let text = raw(first, kAXValueAttribute) as? String,
           let word = text.split(whereSeparator: { $0.isWhitespace }).first {
            let length = String(word).utf16.count
            let start = CFAbsoluteTimeGetCurrent()
            out["first_word_rect"] = bounds(first, CFRange(location: 0, length: length)).map(json)
            out["first_word_ms"] = ((CFAbsoluteTimeGetCurrent() - start) * 1000 * 100).rounded() / 100
            out["first_leaf_frame"] = frame(first).map(json)
        }
        return out
    }

    /// Rects for up to three words of the draft (first, middle, last), as an in-place highlight
    /// would need them: by character range, by text marker range, and the line they are on.
    /// Numbers only; the draft is read to find word boundaries and never recorded.
    private nonisolated static func words(_ element: AXUIElement) -> [[String: Any]] {
        guard let text = raw(element, kAXValueAttribute) as? String, !text.isEmpty else { return [] }
        var ranges: [NSRange] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            ranges.append(NSRange(range, in: text))
        }
        guard !ranges.isEmpty else { return [] }
        let picks = Array(Set([0, ranges.count / 2, ranges.count - 1])).sorted().map { ranges[$0] }
        return picks.map { word in
            var out: [String: Any] = ["range": [word.location, word.length]]
            var start = CFAbsoluteTimeGetCurrent()
            out["range_rect"] = bounds(element, CFRange(location: word.location, length: word.length)).map(json)
            out["range_ms"] = ((CFAbsoluteTimeGetCurrent() - start) * 1000 * 100).rounded() / 100
            // Chromium loads inline text boxes lazily: a first bounds query can come back empty.
            Thread.sleep(forTimeInterval: 0.3)
            out["range_rect_again"] = bounds(element, CFRange(location: word.location, length: word.length)).map(json)
            start = CFAbsoluteTimeGetCurrent()
            if let rect = markerBounds(element, word) { out["marker"] = json(rect) }
            out["marker_ms"] = ((CFAbsoluteTimeGetCurrent() - start) * 1000 * 100).rounded() / 100
            if let line = parameterized(element, kAXLineForIndexParameterizedAttribute, word.location as CFNumber) as? NSNumber {
                out["line"] = line.intValue
                if let value = parameterized(element, kAXRangeForLineParameterizedAttribute, line), CFGetTypeID(value) == AXValueGetTypeID(),
                   let range = cfRange(value as! AXValue) { out["line_range"] = [range.location, range.length] }
            }
            return out
        }
    }
    /// WebKit's path: index → marker, two markers → marker range, marker range → bounds. Chromium
    /// counts marker indexes from the page root, so there it answers the page's bounds instead.
    private nonisolated static func markerBounds(_ element: AXUIElement, _ range: NSRange) -> CGRect? {
        guard let start = parameterized(element, "AXTextMarkerForIndex", range.location as CFNumber),
              let end = parameterized(element, "AXTextMarkerForIndex", NSMaxRange(range) as CFNumber),
              let markers = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray),
              let value = parameterized(element, "AXBoundsForTextMarkerRange", markers), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return rect(value as! AXValue)
    }

    private nonisolated static func caret(_ element: AXUIElement, _ selection: CFRange?) -> [String: Any] {
        var result: [String: Any] = [:]
        if let selection {
            let start = CFAbsoluteTimeGetCurrent()
            result["range"] = bounds(element, CFRange(location: selection.location, length: 0)).map(json)
            result["range_ms"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if selection.location > 0 { result["previous_character"] = bounds(element, CFRange(location: selection.location - 1, length: 1)).map(json) }
            if selection.length > 0 { result["selection"] = bounds(element, selection).map(json) }
        }
        if let markers = raw(element, "AXSelectedTextMarkerRange") {
            let start = CFAbsoluteTimeGetCurrent()
            if let value = parameterized(element, "AXBoundsForTextMarkerRange", markers), CFGetTypeID(value) == AXValueGetTypeID() {
                result["marker"] = rect(value as! AXValue).map(json)
            }
            result["marker_ms"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
            result["marker_length"] = (parameterized(element, "AXLengthForTextMarkerRange", markers) as? NSNumber)?.intValue
        }
        return result
    }

    /// System-wide focus first, then the frontmost app, then helper processes it hosts (Teams'
    /// composer lives in a separate WebView process). Records each step's AXError. If nothing is
    /// focused anywhere, records what each process exposes, reads the app's role and children
    /// (Chromium enables accessibility lazily when a client does) and retries once.
    private nonisolated static func focused(_ system: AXUIElement, _ front: NSRunningApplication?, _ lookup: inout [String: Any]) -> AXUIElement? {
        let prefix = (front?.bundleIdentifier ?? "") + "."
        let processes = (front.map { [($0, "frontmost")] } ?? []) + NSWorkspace.shared.runningApplications
            .filter { front != nil && $0.bundleIdentifier?.hasPrefix(prefix) == true }.map { ($0, $0.bundleIdentifier ?? "helper") }
        func pass(_ log: inout [String: Any]) -> AXUIElement? {
            let sources = [(system, "system")] + processes.map { (AXUIElementCreateApplication($0.0.processIdentifier), $0.1) }
            for (source, label) in sources {
                AXUIElementSetMessagingTimeout(source, 0.5)
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(source, kAXFocusedUIElementAttribute as CFString, &value)
                log[label] = error.rawValue
                if error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    log["source"] = label; return (value as! AXUIElement)
                }
            }
            return nil
        }
        if let element = pass(&lookup) { return element }
        var trees: [String: Any] = [:]
        for (process, label) in processes {
            let app = AXUIElementCreateApplication(process.processIdentifier)
            trees[label] = ["role": raw(app, kAXRoleAttribute) as? String ?? "none",
                            "windows": (raw(app, kAXWindowsAttribute) as? [AXUIElement])?.count ?? -1,
                            "children": (raw(app, kAXChildrenAttribute) as? [AXUIElement])?.count ?? -1,
                            "focused_window": child(app, kAXFocusedWindowAttribute) != nil]
        }
        lookup["trees"] = trees
        Thread.sleep(forTimeInterval: 1)
        var retry: [String: Any] = [:]
        let element = pass(&retry)
        lookup["retry"] = retry
        return element
    }
    private nonisolated static func raw(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AccessibilityExecution.perform(for: element) {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
    }
    // Conditional casts to CF types always succeed in Swift, so check the type ID instead.
    private nonisolated static func child(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = raw(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private nonisolated static func value(_ element: AXUIElement, _ name: String) -> AXValue? {
        guard let value = raw(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
    private nonisolated static func describe(_ value: CFTypeRef?) -> String {
        guard let value else { return "unset" }
        return (value as? NSNumber).map { $0.boolValue ? "true" : "false" } ?? "other"
    }
    private nonisolated static func range(_ element: AXUIElement) -> CFRange? {
        value(element, kAXSelectedTextRangeAttribute).flatMap(cfRange)
    }
    private nonisolated static func cfRange(_ value: AXValue) -> CFRange? {
        var range = CFRange(); return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }
    private nonisolated static func rect(_ value: AXValue) -> CGRect? {
        var rect = CGRect.zero; return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }
    private nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        if let frame = value(element, "AXFrame").flatMap(rect) { return frame }
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    private nonisolated static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range),
              let value = parameterized(element, kAXBoundsForRangeParameterizedAttribute, parameter),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return rect(value as! AXValue)
    }
    private nonisolated static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        AccessibilityExecution.perform(for: element) {
            var value: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
        }
    }
    nonisolated static func json(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 10).rounded() / 10 }
    }
}
