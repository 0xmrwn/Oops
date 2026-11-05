import SwiftUI

/// One window's draft state, driven by `HelloDirector`.
@MainActor @Observable final class HelloWindowState: Identifiable {
    let draft: HelloDraft
    /// Characters of the draft typed so far; nil shows it whole.
    var typed: Int?
    var corrected = false
    /// The corrected words' highlight, 0…1, as on the Try page.
    var flash = 0.0
    var caret = false
    /// On the desktop; the waiting windows appear as the camera pulls back.
    var shown = true
    let drop = CapsuleModel()
    var id: HelloDraft.App { draft.app }
    init(_ draft: HelloDraft) { self.draft = draft; drop.alignment = .bottom }
}

/// A draft as its app shows it: mentions as chips, code in a monospaced chip, the corrected words
/// highlighted. One `Text` with a renderer for the shapes behind the glyphs, so wrapping, right to
/// left and every script stay the system's own.
struct HelloDraftText: View {
    let state: HelloWindowState
    /// Points in the zoomed layout, like every size on Hello's desktop.
    var size: CGFloat = u(13)
    var color: Color = .primary
    var chip = Color(red: 0.07, green: 0.39, blue: 0.64)

    var body: some View {
        text
            .font(.system(size: size))
            .foregroundStyle(color)
            .lineSpacing(u(2))
            .textRenderer(HelloRunRenderer(flash: state.flash, caret: state.caret, chip: chip))
            .environment(\.layoutDirection, state.draft.rightToLeft ? .rightToLeft : .leftToRight)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.12), value: state.corrected)
            .environment(\.locale, Locale(identifier: state.draft.language))
    }

    private var text: Text {
        let draft = state.draft
        let shown = state.corrected ? draft.after : String(draft.before.prefix(state.typed ?? draft.before.count))
        let flashed = state.corrected ? draft.diff.afterRanges : []
        var result = Text(verbatim: "")
        for run in Self.runs(shown, flashed: flashed) {
            var piece = Text(verbatim: run.text)
            switch run.kind {
            case .mention: piece = piece.fontWeight(.medium).foregroundStyle(chip)
            case .code: piece = piece.font(.system(size: size * 0.86, design: .monospaced)).foregroundStyle(Color(red: 0.75, green: 0.07, blue: 0.26))
            default: break
            }
            result = Text("\(result)\(piece.customAttribute(HelloRun(kind: run.kind)))")
        }
        if state.typed != nil, !state.corrected { result = Text("\(result)\(Text(verbatim: " ").customAttribute(HelloRun(kind: .caret)))") }
        return result
    }

    /// Splits the shown text at mention, code and highlight edges (UTF-16 offsets, as `WordDiff` gives them).
    static func runs(_ text: String, flashed: [NSRange]) -> [(text: String, kind: HelloRun.Kind)] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var kinds = [HelloRun.Kind](repeating: .plain, count: ns.length)
        func mark(_ pattern: String, _ kind: HelloRun.Kind) {
            for match in (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                for i in match.range.location..<NSMaxRange(match.range) { kinds[i] = kind }
            }
        }
        mark(#"@\w+"#, .mention)
        mark(#"`[^`]+`"#, .code)
        for range in flashed where NSMaxRange(range) <= ns.length { for i in range.location..<NSMaxRange(range) { kinds[i] = .flash } }
        var runs: [(String, HelloRun.Kind)] = [], start = 0
        for i in 1...ns.length where i == ns.length || kinds[i] != kinds[start] {
            runs.append((ns.substring(with: NSRange(location: start, length: i - start)), kinds[start])); start = i
        }
        return runs
    }
}

struct HelloRun: TextAttribute {
    enum Kind: Hashable { case plain, mention, code, flash, caret }
    let kind: Kind
}

/// Draws the chips, the highlight and the caret behind their runs, then the glyphs.
struct HelloRunRenderer: TextRenderer, Animatable {
    var flash: Double
    var caret: Bool
    var chip: Color
    var animatableData: Double {
        get { flash }
        set { flash = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                let bounds = run.typographicBounds.rect
                switch run[HelloRun.self]?.kind {
                case .mention?: fill(bounds.insetBy(dx: u(-2.5), dy: u(-0.5)), chip.opacity(0.13), in: &context)
                case .code?: fill(bounds.insetBy(dx: u(-2.5), dy: u(-0.5)), Color.black.opacity(0.06), in: &context)
                case .flash? where flash > 0: fill(bounds.insetBy(dx: u(-2), dy: u(-0.5)), Color.accentColor.opacity(0.3 * flash), in: &context)
                case .caret? where caret:
                    context.fill(Path(CGRect(x: bounds.minX + u(1), y: bounds.minY + u(1), width: u(2), height: bounds.height - u(1))), with: .color(.accentColor))
                default: break
                }
                context.draw(run)
            }
        }
    }

    private func fill(_ rect: CGRect, _ color: Color, in context: inout GraphicsContext) {
        context.fill(RoundedRectangle(cornerRadius: min(rect.height / 2, u(5)), style: .continuous).path(in: rect), with: .color(color))
    }
}
