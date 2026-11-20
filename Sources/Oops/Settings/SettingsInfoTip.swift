import SwiftUI

/// What a setting does, instead of a description under every row: an ⓘ that opens a glass popover, after a short
/// hover or on a click, which keeps it open until a click elsewhere or Escape. It holds a title, a sentence or two,
/// and, where words fall short, a small picture of the setting at work. Tab reaches it and Space opens it.
struct InfoTip<Visual: View>: View {
    let title: String?
    let text: String
    @ViewBuilder let visual: Visual
    @State private var shown = false
    /// Opened by a click rather than a hover: leaving it doesn't close it.
    @State private var pinned = false
    @State private var overIcon = false
    @State private var overTip = false
    @State private var pending: Task<Void, Never>?

    init(_ title: String?, _ text: String, @ViewBuilder visual: () -> Visual) {
        self.title = title; self.text = text; self.visual = visual()
    }

    var body: some View {
        Button {
            pending?.cancel()
            pinned = !(pinned && shown)
            shown = pinned
        } label: {
            Image(systemName: "info.circle").font(.system(size: 13)).secondaryText()
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The plain style draws no ring; this one shows only once the keyboard is in use.
        .modifier(FocusVisibleRing(radius: 11))
        // Opened from the keyboard, focus stays here rather than in the popover, so Escape is heard here.
        .onExitCommand { shown = false }
        .onHover { overIcon = $0; hovered() }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            tip.onHover { overTip = $0; hovered() }
        }
        .onChange(of: shown) { if !shown { pinned = false } }
        .accessibilityLabel(title ?? "About this setting")
        .accessibilityHint(text)
    }

    private var tip: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            Text(text).fixedSize(horizontal: false, vertical: true)
            visual
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    /// A hover opens it after a beat, so passing over the icon does nothing; leaving the icon and the tip closes a
    /// hovered one after a shorter beat, long enough to cross from one to the other.
    private func hovered() {
        pending?.cancel()
        let over = overIcon || overTip
        guard over ? !shown : shown, !pinned else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(over ? 300 : 200))
            guard !Task.isCancelled else { return }
            shown = over
        }
    }
}

extension InfoTip where Visual == EmptyView {
    init(_ text: String) { self.init(nil, text) { EmptyView() } }
}

/// Clean up's tip: what Basic does to a few things said, as they're written.
struct CleanupExamples: View {
    private static let examples = [("so um I think", "so I think"), ("new paragraph", "↵"), ("question mark", "?")]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(Self.examples, id: \.0) { said, written in
                GridRow {
                    Text("“\(said)”").secondaryText()
                    Image(systemName: "arrow.right").font(.caption.weight(.semibold)).secondaryText().accessibilityHidden(true)
                    Text(written).fontWeight(.medium)
                }
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Live words' tip: the same words arriving in the drop and at the caret, side by side, on a loop.
struct LiveWordsPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let words = ["see", "you", "at", "the", "meeting"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            // Two words a second, then the whole line for a moment before it starts again.
            let step = reduceMotion ? Self.words.count : Int(context.date.timeIntervalSinceReferenceDate / 0.35) % (Self.words.count + 4)
            let heard = Self.words.prefix(min(step, Self.words.count)).joined(separator: " ")
            HStack(spacing: 10) {
                pane("In the drop") {
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        // The newest words, as the drop's shelf keeps them.
                        Text(heard.isEmpty ? " " : heard).font(.system(size: 10)).lineLimit(1).truncationMode(.head)
                            .padding(.horizontal, 8).frame(width: 112, height: 22)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                pane("At the caret") {
                    // One run of text, so the words wrap like a draft's; the caret follows the last of them.
                    Text("Hi Sam, \(Text(heard).foregroundStyle(.secondary))\(Text("|").foregroundStyle(.tint))")
                        .font(.system(size: 10))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func pane(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            content().padding(8).frame(height: 62).frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
            Text(title).font(.caption).secondaryText()
        }
    }
}
