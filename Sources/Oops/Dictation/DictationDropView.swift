import AppKit
import OopsCore
import SwiftUI

/// The dictation drop: Fix's clear glass capsule at its height, holding its visualizer and a word or two in the
/// drop's type, with the same halo instead of a backing shape. It enters and leaves as Fix's drop does, on
/// the panel's `presented`. Its one action, when a state offers one, sits in the trailing cap as Fix's does;
/// without one it has nothing to press and lets clicks through. While a dictation streams, the glass opens into a
/// shelf on the side away from the edge the drop hugs (`DropShelf`), and its words so far show there
/// (`DictationLivePreview`).
struct DictationDropView: View {
    let model: DictationDropModel
    /// The panel's model, read only for the entrance, the corner and the drop's width.
    @ObservedObject var capsule: CapsuleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    private static let font = DictationLivePreview.font
    private static let spacing: CGFloat = 7, padding: CGFloat = 16
    /// Between the label and the action's cap, as in Fix's drop.
    private static let gap: CGFloat = 6

    private var increasedContrast: Bool { contrast == .increased }
    private var ink: Color { scheme == .dark ? .white : Color(red: 0.06, green: 0.06, blue: 0.09) }
    private var halo: Color { increasedContrast || inked ? .clear : (scheme == .dark ? Color.black : .white).opacity(0.85) }
    /// Reduce Transparency fills the drop, so the appearance's ink is already the right one.
    private var inked: Bool { BackdropInk.isAvailable && !reduceTransparency }

    /// Computed rather than measured, so the glass and the pointer's hold area agree.
    private var width: CGFloat {
        let text = (model.state.text as NSString).size(withAttributes: [.font: Self.font]).width.rounded(.up)
        return lead + voice.width + Self.spacing + text + (model.action == nil ? Self.padding : Self.gap + EyesDropView.drop)
    }

    /// The words on the shelf: a recording's, while it has any.
    private var words: LiveWords? { model.state == .recording ? model.words : nil }
    private var shelfMotion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12) }

    private var voice: CGSize { DictationVisualizerView.size(model.visualizer, phase: model.state) }
    /// The ripple sits centred in the drop's leading cap, as Fix's eyes do; the strips sit a little into it.
    private var lead: CGFloat {
        guard model.state.isLive else { return Self.padding }
        return model.visualizer == .ripple ? (EyesDropView.drop - voice.width) / 2 : Self.padding - 4
    }

    var body: some View {
        // The shelf opens away from the edge the drop hugs, which is the side the text is on.
        let above = capsule.alignment.vertical != .top, words = words
        let height = EyesDropView.drop
        ZStack(alignment: above ? .bottom : .top) {
            glass(open: words == nil ? 0 : 1, above: above)
            if let words {
                DictationLivePreview(words: words, ink: ink, halo: halo, inked: inked)
                    .padding(.horizontal, 18)
                    .frame(height: DropShelf.height - height)
                    .frame(maxHeight: .infinity, alignment: above ? .top : .bottom)
                    // They come in once the shelf is there to hold them, and go at once as it folds: never over the page.
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)), removal: .identity))
            }
            drop.frame(width: width, height: height)
        }
        .frame(width: DropShelf.width, height: DropShelf.height)
        .animation(shelfMotion, value: words == nil)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12), value: model.state)
        // From the capsule, wherever it sits in the panel.
        .scaleEffect(capsule.presented ? 1 : 0.35, anchor: UnitPoint(x: 0.5, y: above ? 1 - height / 2 / DropShelf.height : height / 2 / DropShelf.height))
        .opacity(capsule.presented ? 1 : 0)
        .padding(14)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : capsule.presented ? .spring(duration: 0.45, bounce: 0.3) : .easeIn(duration: 0.22),
                   value: capsule.presented)
        .onAppear { capsule.width = width }
        .onChange(of: model.state) { capsule.width = self.width }
        .onChange(of: model.visualizer) { capsule.width = self.width }
        .onChange(of: model.action?.label) { capsule.width = self.width }
        .allowsHitTesting(model.action != nil)
        // Contained, not ignored: ignoring would swallow the action's button, leaving it reachable only as a
        // custom action that assistive tools searching for a button never find.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.state.text)
        .accessibilityHidden(!capsule.presented)
    }

    /// The capsule and its shelf as one piece of glass.
    private func glass(open: CGFloat, above: Bool) -> some View {
        let shape = DropShelf(open: open, capsule: width, above: above)
        return ZStack {
            if reduceTransparency { shape.fill(.background) }
            GlassEffectContainer {
                Color.clear.glassEffect(.clear, in: shape)
            }
        }
    }

    private var drop: some View {
        HStack(spacing: 0) {
            HStack(spacing: Self.spacing) {
                DropVoice(model: model, isDark: scheme == .dark, reduceMotion: reduceMotion)
                    .voiceInk(inked, kind: model.visualizer, state: model.state, increasedContrast: increasedContrast)
                Text(model.state.text).font(Font(Self.font)).lineLimit(1).fixedSize()
                    .foregroundStyle(ink).modifier(Halo(color: halo))
                    .backdropInk(inked)
            }
            .accessibilityHidden(true) // The drop's own label reads the state.
            if let action = model.action {
                Color.clear.frame(width: Self.gap)
                // Once pressed, Copy's icon turns into a check, and pressing again does nothing.
                DropActionButton(symbol: model.copied ? "checkmark" : action.symbol, label: action.label) {
                    if !model.copied { action.perform() }
                }
                    .foregroundStyle(ink).help(action.label)
            }
        }
        .environment(\.backdropInked, inked)
        .padding(.leading, lead).padding(.trailing, model.action == nil ? Self.padding : 0)
    }
}

/// The drop's voice. It reads the level here, so each frame's change redraws the voice and not the drop around it.
private struct DropVoice: View {
    let model: DictationDropModel
    let isDark: Bool
    let reduceMotion: Bool

    /// Hex draws on its own display link and reads the level there, so nothing here changes per frame.
    private var live: (@MainActor () -> Float)? {
        guard model.visualizer == .hex, let feed = model.loudness else { return nil }
        return { @MainActor in feed.level }
    }

    var body: some View {
        let live = live
        DictationVisualizerView(kind: model.visualizer, phase: model.state, loudness: live == nil ? model.loudness?.level ?? 0 : 0,
                                live: live, isDark: isDark, reduceMotion: reduceMotion)
    }
}
