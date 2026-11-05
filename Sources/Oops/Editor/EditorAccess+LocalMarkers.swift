import AppKit
import ApplicationServices
import OopsCore

extension EditorAccess {
    /// Offsets within this field, independent of document-wide index conversion around objects.
    nonisolated func localMarkerSelection(_ element: AXUIElement, selected: AXTextMarkerRange) -> NSRange? {
        guard let whole = parameterized(element, "AXTextMarkerRangeForUIElement", element),
              CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID(),
              let text = parameterized(element, "AXStringForTextMarkerRange", whole) as? String else { return nil }
        let start = AXTextMarkerRangeCopyStartMarker(whole as! AXTextMarkerRange)
        let selectedStart = AXTextMarkerRangeCopyStartMarker(selected), selectedEnd = AXTextMarkerRangeCopyEndMarker(selected)
        guard let prefixRange = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, selectedStart] as CFArray),
              CFGetTypeID(prefixRange) == AXTextMarkerRangeGetTypeID(),
              CFEqual(AXTextMarkerRangeCopyStartMarker(prefixRange as! AXTextMarkerRange), start),
              let prefix = parameterized(element, "AXStringForTextMarkerRange", prefixRange) as? String,
              let content = parameterized(element, "AXStringForTextMarkerRange", selected) as? String,
              let throughEnd = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, selectedEnd] as CFArray),
              let joined = parameterized(element, "AXStringForTextMarkerRange", throughEnd) as? String,
              sameText(joined, prefix + content), text.utf16.starts(with: joined.utf16) else { return nil }
        return TextOffsets.plausible(location: prefix.utf16.count, length: content.utf16.count)
    }

    /// A bounded walk for fields whose document-index conversion cannot address their own text.
    /// Each prefix must still be the field's text; no index from a neighbouring field is accepted.
    nonisolated func localMarkerRange(_ element: AXUIElement, _ requested: NSRange) -> CFTypeRef? {
        guard TextOffsets.plausible(location: requested.location, length: requested.length) != nil,
              let whole = parameterized(element, "AXTextMarkerRangeForUIElement", element),
              CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID(),
              let text = parameterized(element, "AXStringForTextMarkerRange", whole) as? String,
              NSMaxRange(requested) <= text.utf16.count else { return nil }
        if requested == NSRange(location: 0, length: text.utf16.count) { return whole }
        let first = AXTextMarkerRangeCopyStartMarker(whole as! AXTextMarkerRange)
        var cursor: CFTypeRef = first, lower: CFTypeRef? = requested.location == 0 ? first : nil
        if requested.length == 0, requested.location == 0 {
            return parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [first, first] as CFArray)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        var previous = 0
        for _ in 0..<512 {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let next = parameterized(element, "AXNextTextMarkerForTextMarker", cursor), !CFEqual(cursor, next),
                  let prefixRange = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [first, next] as CFArray),
                  let prefix = parameterized(element, "AXStringForTextMarkerRange", prefixRange) as? String,
                  text.utf16.starts(with: prefix.utf16) else { return nil }
            let count = prefix.utf16.count
            guard count >= previous, count <= NSMaxRange(requested) else { return nil }
            if count == requested.location { lower = next }
            if count == NSMaxRange(requested), let lower {
                return parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [lower, next] as CFArray)
            }
            previous = count; cursor = next
        }
        return nil
    }
    /// Anchor both ends inside the word's own text leaf, rather than a neighbouring empty block
    /// that can have the same text offset. The final range must still belong to this field.
    nonisolated func anchoredWordMarkers(_ element: AXUIElement, candidate: CFTypeRef, word: String, at expected: NSRange) -> CFTypeRef? {
        guard CFGetTypeID(candidate) == AXTextMarkerRangeGetTypeID(), !word.isEmpty else { return nil }
        let first = AXTextMarkerRangeCopyStartMarker(candidate as! AXTextMarkerRange)
        var cursor: CFTypeRef = first, lower: CFTypeRef?
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        for _ in 0..<min(512, word.utf16.count + 64) {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let next = parameterized(element, "AXNextTextMarkerForTextMarker", cursor), !CFEqual(next, cursor),
                  let prefixRange = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [first, next] as CFArray),
                  let prefix = parameterized(element, "AXStringForTextMarkerRange", prefixRange) as? String,
                  word.utf16.starts(with: prefix.utf16) else { return nil }
            if !prefix.isEmpty, lower == nil { lower = parameterized(element, "AXPreviousTextMarkerForTextMarker", next) }
            if sameText(prefix, word), let lower,
               let range = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [lower, next] as CFArray),
               CFGetTypeID(range) == AXTextMarkerRangeGetTypeID(),
               let text = parameterized(element, "AXStringForTextMarkerRange", range) as? String, sameText(text, word),
               localMarkerSelection(element, selected: range as! AXTextMarkerRange) == expected { return range }
            cursor = next
        }
        return nil
    }
}
