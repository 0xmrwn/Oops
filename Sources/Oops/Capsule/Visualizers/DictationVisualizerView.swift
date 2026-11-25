import OopsCore
import SwiftUI

/// The dictation drop's voice, in whichever kind Settings picked. Every kind takes the same input: the drop's
/// state and a loudness from 0 to 1, already smoothed, updated at the display's rate. A state with no voice
/// shows the drop's symbol instead.
struct DictationVisualizerView: View {
    let kind: DictationVisualizer
    let phase: DictationDropState
    let loudness: Float
    /// The level read as each frame is drawn, for a voice that draws itself (Hex); `loudness` is then unused.
    var live: (@MainActor () -> Float)?
    let isDark: Bool
    let reduceMotion: Bool
    @Environment(\.voiceOnRegularGlass) private var onRegularGlass

    /// The space a state's voice draws in. Every kind fills the drop's 46 pt capsule and fades into its caps:
    /// wide while it listens, narrower while work is under way, so the state shows in the glass's shape before
    /// anything in it is read. A state with no voice takes the drop's symbol width.
    static func size(_ phase: DictationDropState) -> CGSize {
        switch phase {
        case .recording: CGSize(width: 168, height: EyesDropView.drop)
        case .transcribing, .cleaningUp: CGSize(width: 96, height: EyesDropView.drop)
        case .ready, .written, .failed, .kept, .copied: CGSize(width: 18, height: 18)
        }
    }

    var body: some View {
        let size = Self.size(phase)
        Group {
            if !phase.isLive {
                Image(systemName: phase.symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoiceInk(isDark: isDark).ink).modifier(Halo(color: VoiceInk(isDark: isDark, onRegularGlass: onRegularGlass).halo))
            } else {
                switch kind {
                // Without Metal, or its shader, the scope would draw nothing in a drop that has no words: Wave stands in.
                case .hex where DotScopeMetalPipeline.shared != nil:
                    hexVisualizer(phase: phase, loudness: loudness, live: live, isDark: isDark, reduceMotion: reduceMotion)
                case .hex: WaveVisualizer(phase: phase, loudness: live.map { $0() } ?? loudness, isDark: isDark, reduceMotion: reduceMotion)
                case .string: StringVisualizer(phase: phase, loudness: loudness, isDark: isDark, reduceMotion: reduceMotion)
                case .wave: WaveVisualizer(phase: phase, loudness: loudness, isDark: isDark, reduceMotion: reduceMotion)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true) // The drop's label says what it is doing.
    }
}

/// The drop's ink and halo, for marks drawn rather than typed: the same tones as its text, so a voice reads
/// over any backdrop with no backing shape. Increase Contrast's solid glass needs no halo, and neither does a
/// voice on regular glass, which keeps its content legible by itself.
struct VoiceInk {
    let ink: Color, halo: Color
    init(isDark: Bool, increasedContrast: Bool = false, onRegularGlass: Bool = false) {
        ink = isDark ? .white : Color(red: 0.06, green: 0.06, blue: 0.09)
        halo = increasedContrast || onRegularGlass ? .clear : (isDark ? Color.black : .white).opacity(0.85)
    }
}

extension EnvironmentValues {
    /// Whether the voice sits on regular glass, as the dictation drop's does, and so needs no halo.
    @Entry var voiceOnRegularGlass = false
    /// Whether a voice that draws itself (Hex) holds still at the level it is given, as a preview does under Reduce
    /// Motion, rather than drawing every frame.
    @Entry var voiceHeldStill = false
}
