import OopsCore
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
        // Opened from the keyboard, focus stays here rather than in the popover, so Escape is heard here; closed, it
        // leaves Escape to whatever holds the tip, such as the speech model picker.
        .onExitCommand(perform: shown ? { shown = false } : nil)
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
    init(_ title: String, _ text: String) { self.init(title, text) { EmptyView() } }
}

/// What saying something writes, in a tip: Clean up's and its small cleanups' examples.
struct SaysWrites: View {
    let pairs: [(said: String, written: String)]
    init(_ pairs: [(said: String, written: String)]) { self.pairs = pairs }

    /// What Basic does to a few things said.
    static let cleanup = SaysWrites([("so um I think", "so I think"), ("new line", "↵"), ("question mark", "?")])
    static let fillers = SaysWrites([("um, so uh I think", "so I think"), ("euh, je pense", "je pense")])
    static let formatting = SaysWrites([("new line", "↵"), ("new paragraph", "blank line"), ("open quote hi close quote", "\"hi\"")])
    static let symbols = SaysWrites([("comma · colon · semicolon", ", : ;"), ("question mark · exclamation mark", "? !"),
                                     ("open paren · close paren", "( )"), ("hyphen · slash · underscore", "- / _"),
                                     ("at sign · hashtag", "@ #")])

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(pairs, id: \.said) { said, written in
                GridRow {
                    // What's said takes the room; what's written is a word or a mark.
                    Text("“\(said)”").secondaryText().fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").font(.caption.weight(.semibold)).secondaryText().accessibilityHidden(true)
                    Text(written).fontWeight(.medium).fixedSize()
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

/// Shortcut mode's tip: what a hold and a tap do in each mode, the one chosen in bold.
struct ShortcutModeGuide: View {
    let selected: DictationMode
    private static let modes: [(DictationMode, String)] = [
        (.holdOrTap, "Hold to talk, or tap to keep listening until you press again."),
        (.holdOrDoubleTap, "Hold to talk, or double-tap to keep listening. A single tap writes nothing, so a stray one adds no text."),
        (.holdOnly, "Listens only while you hold the keys."),
        (.tapOnly, "Press to start, press again to stop."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.modes, id: \.0) { mode, meaning in
                let chosen = mode == selected
                VStack(alignment: .leading, spacing: 1) {
                    Text(DictationMode.choices.first { $0.value == mode }?.label ?? "").fontWeight(chosen ? .semibold : .medium)
                    Text(meaning).font(.callout).secondaryText().fixedSize(horizontal: false, vertical: true)
                }
                .opacity(chosen ? 1 : 0.8)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
    }
}

/// Position's tip: a small screen for each place the drop can sit, the one chosen outlined.
struct DropPositionPreview: View {
    let selected: DictationDropPosition
    private static let places: [(DictationDropPosition, String)] = [(.anchored, "By the text"), (.top, "Top"), (.bottom, "Bottom")]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.places, id: \.0) { place, name in
                let chosen = place == selected
                VStack(spacing: 5) {
                    screen(place)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, lineWidth: chosen ? 1.5 : 0))
                    Text(name).font(.caption).fontWeight(chosen ? .semibold : .regular).foregroundStyle(chosen ? .primary : .secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// A screen with a window holding a field, and the drop where `place` puts it.
    private func screen(_ place: DictationDropPosition) -> some View {
        ZStack(alignment: place == .top ? .top : .bottom) {
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
            // The window and its field, off-centre as an app usually sits.
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(width: 52, height: 30)
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                        .frame(width: 42, height: 9).padding(.bottom, 5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).offset(x: -6)
            Capsule().fill(.primary.opacity(0.7)).frame(width: 18, height: 6)
                .offset(x: place == .anchored ? -6 : 0, y: place == .anchored ? -1 : 0)
                .padding(place == .top ? .top : .bottom, place == .anchored ? 13 : 4)
        }
        .frame(width: 84, height: 54)
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
