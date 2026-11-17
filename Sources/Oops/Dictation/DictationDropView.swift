import AppKit
import OopsCore
import SwiftUI

/// The dictation drop: a capsule of regular Liquid Glass at Fix's drop's height, holding its voice, or its symbol
/// and a word or two in the drop's type (`DictationCapsule`). Work under way and a plain success say nothing: the
/// capsule's shape tells the state. Everything it shows is the glass's own content in the system's foreground
/// styles, so the system keeps it legible, in one colour, over whatever is behind. It enters and leaves as Fix's
/// drop does, on the panel's `presented`. Its one action, when a state offers one, sits in the trailing cap as
/// Fix's does; without one it has nothing to press and lets clicks through. While a dictation streams, the glass
/// opens into a shelf on the side away from the edge the drop hugs (`DropShelf`), and its words so far show there
/// (`DictationLivePreview`).
struct DictationDropView: View {
    let model: DictationDropModel
    /// The panel's model, read only for the entrance, the corner and the drop's width.
    @ObservedObject var capsule: CapsuleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var width: CGFloat { DictationCapsuleLayout(model.state, action: model.action != nil).width }

    /// The words on the shelf: a recording's, while it has any.
    private var words: LiveWords? { model.state == .recording ? model.words : nil }
    private var shelfMotion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12) }

    /// The page's appearance where the field tells it, the system's otherwise: the glass and all it holds take it.
    private var dark: Bool { model.pageDark ?? (scheme == .dark) }

    var body: some View {
        // The shelf opens away from the edge the drop hugs, which is the side the text is on.
        let above = capsule.alignment.vertical != .top, words = words
        let height = EyesDropView.drop
        ZStack(alignment: above ? .bottom : .top) {
            if let words {
                DictationLivePreview(words: words)
                    .padding(.horizontal, 18)
                    .frame(height: DropShelf.height - height)
                    .frame(maxHeight: .infinity, alignment: above ? .top : .bottom)
                    // They come in once the shelf is there to hold them, and go at once as it folds: never over the page.
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)), removal: .identity))
            }
            DictationCapsule(state: model.state, action: model.action, copied: model.copied) {
                DropVoice(model: model, isDark: dark, reduceMotion: reduceMotion)
            }
        }
        .frame(width: DropShelf.width, height: DropShelf.height, alignment: above ? .bottom : .top)
        // The capsule and its shelf as one piece of glass, with everything above as its content.
        .glassEffect(.regular, in: DropShelf(open: words == nil ? 0 : 1, capsule: width, above: above))
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
        .onChange(of: model.action?.label) { capsule.width = self.width }
        .allowsHitTesting(model.action != nil)
        // Contained, not ignored: ignoring would swallow the action's button, leaving it reachable only as a
        // custom action that assistive tools searching for a button never find.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.state.text)
        .accessibilityHidden(!capsule.presented)
        .environment(\.colorScheme, dark ? .dark : .light)
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
