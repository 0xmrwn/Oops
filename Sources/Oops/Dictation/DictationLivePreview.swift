import AppKit
import OopsCore
import SwiftUI

/// The words so far, on the drop's shelf: the newest two lines in the drop's type, as content of its glass. They
/// wrap from the left and stay put as words arrive; a third line pushes the oldest out over the top. The words the
/// engine may still change take the system's secondary style.
struct DictationLivePreview: View {
    let words: LiveWords
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The state word's type.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let spacing: CGFloat = 2
    /// Two lines of that type.
    static let height: CGFloat = 2 * NSLayoutManager().defaultLineHeight(for: font).rounded(.up) + spacing
    /// A long dictation lays out its newest words only, cut in steps this long: each cut wraps the lines afresh,
    /// so they are rare.
    private static let step = 1000

    var body: some View {
        Self.text(recent)
            .lineSpacing(Self.spacing).multilineTextAlignment(.leading)
            .contentTransition(.identity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: Self.height, alignment: .bottom)
            .clipped()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: words)
            // Read with the drop, never announced: it changes with every word.
            .accessibilityLabel(words.text)
    }

    /// `words` without the steps of settled text that two lines left behind long ago.
    private var recent: LiveWords {
        let cut = (words.stable.count / Self.step - 1) * Self.step
        guard cut > 0 else { return words }
        let rest = words.stable.dropFirst(cut)
        return LiveWords(stable: String(rest.drop { !$0.isWhitespace }), changing: words.changing)
    }

    /// `words` in the drop's type: the system's primary style, and its secondary for the part that may still change.
    static func text(_ words: LiveWords) -> Text {
        // The engines give each part with its own spacing; the first line starts at its first word.
        let lead = words.stable.drop(while: \.isWhitespace)
        let rest = lead.isEmpty ? words.changing.drop(while: \.isWhitespace) : words.changing[...]
        return Text("\(Text(String(lead)).foregroundStyle(.primary))\(Text(String(rest)).foregroundStyle(.secondary))").font(Font(font))
    }
}
