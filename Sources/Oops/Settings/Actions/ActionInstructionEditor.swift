import AppKit
import OopsCore
import SwiftUI

// The instruction is a text view, and the action's one choice is a pill inside it, an attachment that moves with the
// words around it and deletes like a character. Clicking it opens the choice's setup.

/// Text beyond the editor's top or bottom edge.
struct Hidden: Equatable {
    var above = false, below = false
}

/// What the buttons around the editor ask of its text view.
@MainActor final class InstructionController {
    weak var coordinator: InstructionText.Coordinator?

    /// A pill at the caret, or at the end when the editor isn't being edited; then its setup.
    func insertChoice() { coordinator?.insertChoice() }
    func openChoice() { coordinator?.openChoice() }
}

/// The pill's size and where it sits on the line, shared by the attachment (layout) and the pill (drawing).
enum PillMetrics {
    nonisolated(unsafe) static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let height: CGFloat = 20
    static let padding: CGFloat = 8
    static let chevron: CGFloat = 7, gap: CGFloat = 4
    /// Room either side, so the pill never touches the letters next to it.
    static let margin: CGFloat = 2
    /// Every line is this tall, so a line with a pill keeps the same rhythm as one without.
    static let line: CGFloat = 22

    static func label(_ name: String) -> String { name.isEmpty ? "Choice" : name }

    static func width(_ name: String) -> CGFloat {
        let text = (label(name) as NSString).size(withAttributes: [.font: font]).width
        return ceil(text + gap + chevron + 2 * padding)
    }

    /// The pill's label sits on the text's baseline: centred in the pill, its baseline is this far above the pill's
    /// bottom edge, so the pill starts this far below the line's.
    static var drop: CGFloat {
        let box = font.ascender - font.descender
        return ((height - box) / 2 - font.descender).rounded(.toNearestOrAwayFromZero)
    }
}

/// The instruction's text in a well three lines tall, growing to eight and then scrolling inside.
struct InstructionEditor: View {
    let library: ActionLibraryModel
    let navigation: ActionsNavigation
    let id: UUID
    let controller: InstructionController
    /// The skills the instruction may name, empty while it may not.
    var skills: [String] = []
    @State private var height: CGFloat = 0
    @State private var hidden = Hidden()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsStyle) private var style
    static let inset = CGSize(width: 18, height: 12)

    private var empty: Bool { library.action(id)?.instruction.isEmpty ?? true }
    /// Passed down so a renamed choice lays the text out again, its pill being as wide as its name.
    private var choiceName: String { library.action(id)?.choice?.name ?? "" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        let lines = min(max(height, 3 * PillMetrics.line), 8 * PillMetrics.line)
        InstructionText(library: library, navigation: navigation, id: id, controller: controller, style: style,
                        label: choiceName, skills: skills, height: $height, hidden: $hidden)
            .frame(height: lines + 2 * Self.inset.height)
            // Past eight lines the text scrolls inside: the edge with more beyond it fades out.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(hidden.above ? 0 : 1), .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(hidden.below ? 0 : 1)], startPoint: .top, endPoint: .bottom).frame(height: 18)
                }
            }
            .overlay(alignment: .topLeading) {
                if empty {
                    Text("What should Oops do with the text?").font(.system(size: 13)).secondaryText().opacity(0.7)
                        .frame(height: PillMetrics.line)
                        .padding(.leading, Self.inset.width).padding(.top, Self.inset.height).allowsHitTesting(false)
                }
            }
            .background { shape.fill(Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.16 : 0.42)) }
            .glassEffect(.clear, in: shape)
            .glassEdge(shape, outside: true)
            .animation(.easeOut(duration: 0.12), value: lines)
    }
}

/// The choice as the app's glass chip: its name and a chevron, on the text's baseline.
struct ChoicePill: View {
    let library: ActionLibraryModel
    let id: UUID
    let open: () -> Void

    var body: some View {
        let name = library.action(id)?.choice?.name ?? ""
        Button(action: open) {
            HStack(spacing: PillMetrics.gap) {
                Text(PillMetrics.label(name)).font(Font(PillMetrics.font)).lineLimit(1)
                    .foregroundStyle(.primary.opacity(name.isEmpty ? 0.55 : 1))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).secondaryText()
                    .frame(width: PillMetrics.chevron)
            }
            .padding(.horizontal, PillMetrics.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEdge(Capsule())
        .help("Set up the choice")
        .accessibilityLabel(PillMetrics.label(name))
        .accessibilityHint("Choice")
    }
}
