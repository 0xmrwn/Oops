import AppKit
import ApplicationServices
import OopsCore

/// The text and selection of a WebKit or Chromium document that exposes no plain value (Mail's
/// message body), through text markers: the element's whole marker range for its text, and
/// index ↔ marker conversions for the selection, in the same character offsets.
extension EditorAccess {
    nonisolated func markerText(_ element: AXUIElement) -> String? {
        guard let whole = parameterized(element, "AXTextMarkerRangeForUIElement", element) else { return nil }
        return parameterized(element, "AXStringForTextMarkerRange", whole) as? String
    }

    nonisolated func markerSelection(_ element: AXUIElement) -> NSRange? {
        guard let selected = attribute(element, "AXSelectedTextMarkerRange"),
              CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = selected as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(range), end = AXTextMarkerRangeCopyEndMarker(range)
        if let lower = parameterized(element, "AXRelativeIndexForTextMarker", start) as? NSNumber,
           let upper = parameterized(element, "AXRelativeIndexForTextMarker", end) as? NSNumber,
           let selection = TextOffsets.between(lower.intValue, upper.intValue, from: 0) { return selection }
        if let local = localMarkerSelection(element, selected: range) { return local }
        guard let base = markerBase(element),
              let lower = (parameterized(element, "AXIndexForTextMarker", start) as? NSNumber)?.intValue,
              let upper = (parameterized(element, "AXIndexForTextMarker", end) as? NSNumber)?.intValue,
              let selection = TextOffsets.between(lower, upper, from: base) else { return nil }
        return selection
    }

    /// Where the element's own text starts among the indexes its markers convert: WebKit and Chromium
    /// count from the element, Gecko from the document. The one whose markers cover exactly the
    /// element's text, or nil when neither does and offsets can't be trusted.
    nonisolated func markerBase(_ element: AXUIElement) -> Int? {
        guard let whole = parameterized(element, "AXTextMarkerRangeForUIElement", element),
              CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID(),
              let text = parameterized(element, "AXStringForTextMarkerRange", whole) as? String else { return nil }
        let start = (parameterized(element, "AXIndexForTextMarker", AXTextMarkerRangeCopyStartMarker(whole as! AXTextMarkerRange))
            as? NSNumber)?.intValue ?? 0
        // An engine may answer NSNotFound: only a plausible document offset is a candidate.
        return ([0] + ((1..<TextOffsets.limit).contains(start) ? [start] : [])).first { base in
            markerRange(element, NSRange(location: 0, length: text.utf16.count), base: base)
                .flatMap { parameterized(element, "AXStringForTextMarkerRange", $0) as? String }.map { sameText($0, text) } ?? false
        }
    }

    nonisolated func markerRange(_ element: AXUIElement, _ range: NSRange, base: Int? = nil) -> CFTypeRef? {
        if let offset = base ?? markerBase(element), let valid = TextOffsets.plausible(location: range.location, length: range.length),
           offset <= TextOffsets.limit,
           let start = parameterized(element, "AXTextMarkerForIndex", (valid.location + offset) as CFNumber),
           let end = parameterized(element, "AXTextMarkerForIndex", (NSMaxRange(valid) + offset) as CFNumber),
           let markers = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray) { return markers }
        // An explicit base is a probe of index conversion itself; never make it look supported
        // through a different API. Ordinary field requests may use the bounded local walk.
        return base == nil ? localMarkerRange(element, range) : nil
    }

    /// A marker range returned by the field's own search, when document-wide indexes cannot
    /// reach a shadow tree. Both relative endpoints and the word must match before any edit.
    nonisolated func searchedMarkerRange(_ element: AXUIElement, _ range: NSRange, word: String) -> CFTypeRef? {
        let criteria: [String: Any] = ["AXSearchTextSearchStrings": [word], "AXSearchTextStartFrom": "AXSearchTextStartFromBegin",
                                      "AXSearchTextDirection": "AXSearchTextDirectionAll"]
        guard !word.isEmpty, word.utf16.count <= 128,
              let found = parameterized(element, "AXSearchTextWithCriteria", criteria as CFDictionary) as? [CFTypeRef] else { return nil }
        for item in found where CFGetTypeID(item) == AXTextMarkerRangeGetTypeID() {
            let markers = item as! AXTextMarkerRange
            guard let start = parameterized(element, "AXRelativeIndexForTextMarker", AXTextMarkerRangeCopyStartMarker(markers)) as? NSNumber,
                  let end = parameterized(element, "AXRelativeIndexForTextMarker", AXTextMarkerRangeCopyEndMarker(markers)) as? NSNumber,
                  start.intValue == range.location, end.intValue == NSMaxRange(range),
                  let text = parameterized(element, "AXStringForTextMarkerRange", item) as? String,
                  sameText(Self.visible(text), Self.visible(word)) else { continue }
            return item
        }
        return nil
    }

    nonisolated func provedWordMarkers(_ element: AXUIElement, edit: TextChange, draft: String) -> CFTypeRef? {
        let operations = AccessibilityExecution.perform(for: element) {
            var names: CFArray?
            return AXUIElementCopyParameterizedAttributeNames(element, &names) == .success ? names as? [String] ?? [] : []
        }
        guard operations.contains("AXTextOperation"), let marked = markerText(element),
              let mapped = MarkerOffsets.range(edit.range, from: draft, to: marked)
                ?? (DisplayOrder.reordered(marked, of: draft, awayFrom: edit.range) ? edit.range : nil) else { return nil }
        if let markers = markerRange(element, mapped),
           let anchored = anchoredWordMarkers(element, candidate: markers, word: edit.original, at: mapped) { return anchored }
        if let found = searchedMarkerRange(element, mapped, word: edit.original),
           let anchored = anchoredWordMarkers(element, candidate: found, word: edit.original, at: mapped) { return anchored }
        if let local = localMarkerRange(element, mapped) {
            return anchoredWordMarkers(element, candidate: local, word: edit.original, at: mapped)
        }
        return nil
    }

    /// The text a marker range covers, to check a selection holds what it should before pasting.
    nonisolated func markerString(_ element: AXUIElement, _ range: NSRange) -> String? {
        markerRange(element, range).flatMap { parameterized(element, "AXStringForTextMarkerRange", $0) as? String }
    }

    nonisolated func writeMarkerSelection(_ element: AXUIElement, _ range: NSRange) -> AXError {
        guard let markers = markerRange(element, range) else { return .failure }
        return AccessibilityExecution.perform(for: element) {
            AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, markers)
        }
    }

    /// Whether markers can read and select this element's text: a document with text and a
    /// settable marker selection.
    /// Static text (a menu's option the editor points at, say) is never a draft.
    nonisolated func supportsMarkers(_ element: AXUIElement) -> Bool {
        attribute(element, kAXRoleAttribute) as? String != kAXStaticTextRole
            && markerText(element) != nil && markerSelection(element) != nil && settable(element, "AXSelectedTextMarkerRange")
            && (markerBase(element) != nil || (markerText(element)?.utf16.count ?? Int.max) <= 512)
    }

    // MARK: Per strategy

    /// The draft as the strategy reads it.
    nonisolated func text(_ element: AXUIElement, _ strategy: CaptureStrategy) -> String? {
        switch strategy {
        case .markers, .atoms: markerText(element)
        case .value, .copy: attribute(element, kAXValueAttribute) as? String
        }
    }
    nonisolated func selection(_ element: AXUIElement, _ strategy: CaptureStrategy) -> NSRange? {
        strategy == .markers ? markerSelection(element) : range(element)
    }

    /// Text markers, when the value's offsets can't be trusted around atoms: the markers count each
    /// image or chip as one U+FFFC, while the value spells it as its alt text (Chromium), or leaves it
    /// out and the selection lies past its end or on other text (Gecko). Their own selection when it
    /// reads back; else their text with the character ranges.
    nonisolated func consistentStrategy(_ element: AXUIElement, value: String, selection: NSRange) -> CaptureStrategy? {
        guard let text = markerText(element) else { return nil }
        // A selection past the value's end, where the value leaves out a chip its markers hold (Trix's
        // attachment in a Chromium combobox): the markers' text, when the selected text is exactly its
        // text at that range.
        if NSMaxRange(selection) > value.utf16.count, NSMaxRange(selection) <= text.utf16.count,
           let selected = attribute(element, kAXSelectedTextAttribute) as? String,
           sameText(selected, (text as NSString).substring(with: selection)) { return .atoms }
        let spent = TextEdits.atomSpelling(value: value, markers: text)
        guard spent != nil || MarkerOffsets.compatible(value, text) else { return nil }
        let selected = attribute(element, kAXSelectedTextAttribute) as? String
        let outside = NSMaxRange(selection) > value.utf16.count
        let misread = !outside && selection.length > 0
            && selected.map { !sameText($0, (value as NSString).substring(with: selection)) } == true
        guard (spent ?? 0) > 0 || outside || misread else { return nil }
        // Markers all the way when their selection reads back in their own text; else their text with the ranges.
        if supportsMarkers(element), let marked = markerSelection(element), NSMaxRange(marked) <= text.utf16.count { return .markers }
        return .atoms
    }

    nonisolated func select(_ element: AXUIElement, _ range: NSRange, _ strategy: CaptureStrategy) -> AXError {
        strategy == .markers ? writeMarkerSelection(element, range) : writeRange(element, range)
    }
}
