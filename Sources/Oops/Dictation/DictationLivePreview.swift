import AppKit
import OopsCore
import SwiftUI

/// The words so far, on the drop's shelf: the newest two lines in the drop's type, with no shape behind them.
/// They wrap from the left and stay put as words arrive; a third line pushes the oldest out over the top. The
/// words the engine may still change are fainter.
struct DictationLivePreview: View {
    let words: LiveWords
    let ink: Color
    let halo: Color
    let inked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// The state word's type.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let spacing: CGFloat = 2
    /// Two lines of that type.
    static let height: CGFloat = 2 * NSLayoutManager().defaultLineHeight(for: font).rounded(.up) + spacing
    /// A long dictation lays out its newest words only, cut in steps this long: each cut wraps the lines afresh,
    /// so they are rare.
    private static let step = 1000

    var body: some View {
        Self.text(recent, ink: ink)
            .lineSpacing(Self.spacing).multilineTextAlignment(.leading)
            .contentTransition(.identity)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: Self.height, alignment: .bottom)
            .clipped()
            .modifier(Halo(color: halo))
            .backdropInk(inked, contrast: BackdropInk.wordsContrast, lean: scheme == .dark ? BackdropInk.wordsLean : -BackdropInk.wordsLean)
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

    /// `words` in the drop's type, the changing part at 0.6 of the ink: an opacity, so backdrop ink keeps it too.
    static func text(_ words: LiveWords, ink: Color) -> Text {
        // The engines give each part with its own spacing; the first line starts at its first word.
        let lead = words.stable.drop(while: \.isWhitespace)
        var stable = AttributedString(lead), changing = AttributedString(lead.isEmpty ? words.changing.drop(while: \.isWhitespace) : words.changing[...])
        stable.foregroundColor = ink
        changing.foregroundColor = ink.opacity(0.6)
        return Text(stable + changing).font(Font(font))
    }
}
