import AppKit
import OopsCore
import SwiftUI

/// What the dictation drop's capsule holds, inside whatever glass its caller gives it: the voice edge to edge
/// while work is under way, a lone check in a circle for a plain success, and otherwise the symbol and its words.
/// An action, when the state offers one, sits in the trailing cap as Fix's does. The drop and the lab both show
/// this view, so the lab cannot drift from the drop.
struct DictationCapsule<Voice: View>: View {
    let state: DictationDropState
    let action: DropAction?
    /// The kept transcript's copy button was pressed; its icon turns into a check.
    var copied = false
    /// The drop's voice, or its symbol for a state with no voice (`DictationVisualizerView`).
    @ViewBuilder let voice: () -> Voice

    var body: some View {
        let layout = DictationCapsuleLayout(state, action: action != nil)
        HStack(spacing: 0) {
            HStack(spacing: DictationCapsuleLayout.spacing) {
                voice()
                if layout.words { Text(state.text).font(Font(DictationLivePreview.font)).lineLimit(1).fixedSize() }
            }
            .accessibilityHidden(true) // The drop's own label reads the state.
            if let action {
                Color.clear.frame(width: DictationCapsuleLayout.gap)
                // Once pressed, Copy's icon turns into a check, and pressing again does nothing.
                DropActionButton(symbol: copied ? "checkmark" : action.symbol, label: action.label) {
                    if !copied { action.perform() }
                }
                    .help(action.label)
            }
        }
        .foregroundStyle(.primary)
        .environment(\.voiceOnRegularGlass, true)
        .padding(.leading, layout.lead).padding(.trailing, layout.trail)
        .frame(width: layout.width, height: EyesDropView.drop)
        // A voice runs to the capsule's edges and fades into its caps; nothing of it may spill past them.
        .clipShape(Capsule())
    }
}

/// Where the capsule's content sits for a state, and so its width: computed rather than measured, so the glass
/// and the pointer's hold area agree.
@MainActor struct DictationCapsuleLayout {
    static let spacing: CGFloat = 7, padding: CGFloat = 16
    /// Between the content and the action's cap, as in Fix's drop.
    static let gap: CGFloat = 6

    /// Padding before the content, and after it when there is no action; whether the state's words show.
    let lead: CGFloat, trail: CGFloat, words: Bool, width: CGFloat

    init(_ state: DictationDropState, action: Bool) {
        let voice = DictationVisualizerView.size(state).width, drop = EyesDropView.drop
        let side: CGFloat
        if state.isLive {
            (side, words) = (0, false)
        } else if state.needsNoWords {
            // The symbol alone, centred in a circle as Fix's eyes are in its cap.
            (side, words) = ((drop - voice) / 2, false)
        } else {
            (side, words) = (Self.padding, true)
        }
        let text = words ? Self.spacing + (state.text as NSString).size(withAttributes: [.font: DictationLivePreview.font]).width.rounded(.up) : 0
        lead = side
        trail = action ? 0 : side
        width = lead + voice + text + (action ? Self.gap + drop : trail)
    }
}

extension DictationDropState {
    /// Work under way, or its plain success: shown by the voice or the symbol alone. A failure, an instruction and
    /// a kept transcript still have to be read.
    var needsNoWords: Bool {
        switch self {
        case .recording, .transcribing, .cleaningUp, .written, .copied: true
        case .ready, .failed, .kept: false
        }
    }
}
