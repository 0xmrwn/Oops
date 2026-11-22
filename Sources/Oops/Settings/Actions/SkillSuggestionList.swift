import AppKit
import Observation
import SwiftUI

/// What the suggestion list shows and which row is lit.
@MainActor @Observable final class SkillSuggestionModel {
    var sigil: Character = "/"
    var names: [String] = []
    var highlighted = 0
}

/// The names under the caret as a small glass list. It never takes focus: the keys stay with the text, and a row is
/// also clickable.
struct SkillSuggestionList: View {
    static let width: CGFloat = 200, row: CGFloat = 28, padding: CGFloat = 6

    let model: SkillSuggestionModel
    let pick: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    static func height(rows: Int) -> CGFloat { CGFloat(rows) * row + 2 * padding }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        VStack(spacing: 0) {
            ForEach(Array(model.names.enumerated()), id: \.offset) { index, name in
                Button { pick(name) } label: {
                    HStack(spacing: 0) {
                        Text(String(model.sigil)).secondaryText()
                        Text(name).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: Self.row)
                    .background(Color.primary.opacity(index == model.highlighted ? (colorScheme == .dark ? 0.16 : 0.1) : 0), in: .rect(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(index == model.highlighted ? .isSelected : [])
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width, height: Self.height(rows: model.names.count), alignment: .top)
        .glassEffect(.regular, in: shape)
        .glassEdge(shape, outside: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skills")
    }
}

/// A window of its own for the list, so it can reach past Settings' edge; it is never key or main, and a click on it
/// leaves the text view as it was.
final class SkillSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @MainActor init(model: SkillSuggestionModel, pick: @escaping (String) -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = NSHostingView(rootView: SkillSuggestionList(model: model, pick: pick))
    }
}
