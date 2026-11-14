import AppKit
import OopsCore
import SwiftUI

/// The words so far, as one line beside the dictation drop: the drop's type, ink and halo with no shape behind
/// them, the words the engine may still change fainter, and only the newest words that fit.
struct DictationLivePreview: View {
    let words: LiveWords
    /// The widest the line may be: the panel's envelope.
    var width: CGFloat = CapsulePanel.standard.width - 28
    let ink: Color
    let halo: Color
    let inked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The state word's type.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    /// What the line takes beside the capsule, gap included: what the dictation's panel grows by.
    static let room: CGFloat = 28

    var body: some View {
        Self.text(Self.fitted(words, width: width), ink: ink)
            .modifier(Halo(color: halo))
            .backdropInk(inked)
            .frame(height: Self.room)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: words)
            // Read with the drop, never announced: it changes with every word.
            .accessibilityLabel(words.text)
    }

    /// The newest words that fit `width` in the drop's type.
    static func fitted(_ words: LiveWords, width: CGFloat) -> LiveWords {
        words.tail(fitting: width, measure: measure)
    }

    static func measure(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// `words` on one line, the changing part at 0.6 of the ink: an opacity, so backdrop ink keeps it too.
    static func text(_ words: LiveWords, ink: Color) -> some View {
        var stable = AttributedString(words.stable), changing = AttributedString(words.changing)
        stable.foregroundColor = ink
        changing.foregroundColor = ink.opacity(0.6)
        return Text(stable + changing).font(Font(font)).lineLimit(1).fixedSize()
    }
}
