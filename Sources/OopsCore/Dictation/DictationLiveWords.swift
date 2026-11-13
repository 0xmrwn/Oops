import CoreGraphics

/// Where live words appear. The raw values are what Settings stores.
public enum DictationLiveWordsPlace: String, CaseIterable, Sendable {
    /// A line above the drop's visualizer; the text field is untouched until the end.
    case drop
    /// At the caret, over the text field, through the highlight overlay.
    case text
}

/// Where one dictation's words go, from the setting and the field's geometry read as the drop came up.
public enum LiveWordsTarget: Equatable, Sendable {
    case drop
    /// The caret in AX points (top-left, global), and how wide the words may run before the field's edge.
    case caret(CGRect, width: CGFloat)
}

public extension LiveWords {
    /// The newest words that fit `width` on one line, by `measure`: the longest tail of whole words, with "…" in
    /// front when any were left out, still split into the stable and the changing part so each keeps its ink. The
    /// last word stays even when it alone is too wide. Whitespace is joined as `text` joins it.
    func tail(fitting width: CGFloat, measure: (String) -> CGFloat) -> LiveWords {
        let all = Array(stable + changing), boundary = stable.count
        var line: [Character] = [], stableEnd: Int?
        for (index, character) in all.enumerated() {
            if index == boundary { stableEnd = line.count }
            if !character.isWhitespace { line.append(character) } else if let last = line.last, last != " " { line.append(" ") }
        }
        if line.last == " " { line.removeLast() }
        let end = min(stableEnd ?? line.count, line.count)
        func split(from start: Int, ellipsis: Bool) -> LiveWords {
            let cut = max(start, end), mark = ellipsis ? "…" : ""
            let kept = String(line[start ..< cut]), rest = String(line[cut...])
            return kept.isEmpty ? LiveWords(stable: "", changing: mark + rest) : LiveWords(stable: mark + kept, changing: rest)
        }
        // Where each word after the first starts; the width only shrinks as the start moves right.
        let starts = line.indices.filter { $0 > 0 && line[$0 - 1] == " " }
        guard !starts.isEmpty, measure(String(line)) > width else { return split(from: 0, ellipsis: false) }
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high) / 2
            if measure("…" + String(line[starts[middle]...])) <= width { high = middle } else { low = middle + 1 }
        }
        return split(from: starts[low], ellipsis: true)
    }
}
