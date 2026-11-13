import OopsCore
import SwiftUI

/// The dictation drop's voice, in whichever kind Settings picked. Every kind takes the same input: the drop's
/// state and a loudness from 0 to 1, already smoothed, updated at the display's rate. A failure shows the
/// drop's warning symbol rather than a voice, as the drop always has.
struct DictationVisualizerView: View {
    let kind: DictationVisualizer
    let phase: DictationDropState
    let loudness: Float
    let isDark: Bool
    let reduceMotion: Bool
    @Environment(\.backdropInked) private var inked

    /// The space each kind draws in, inside the drop's 46 pt height. The ripple takes a cap of the drop, as
    /// Fix's eyes do; the waveforms take a strip as tall as a line of the drop's text with its halo.
    /// A failure takes the drop's symbol width.
    static func size(_ kind: DictationVisualizer, phase: DictationDropState) -> CGSize {
        guard phase.isLive else { return CGSize(width: 18, height: 18) }
        return switch kind {
        // The scope's own widths: full while it follows the voice, narrower for its shimmer.
        case .hex: CGSize(width: CGFloat(phase == .recording ? DotScopeTuning.hud.width : DotScopeTuning.hud.processingWidth),
                          height: CGFloat(DotScopeTuning.hud.height))
        case .wave: CGSize(width: 64, height: 26)
        case .ripple: CGSize(width: 40, height: 40)
        }
    }

    var body: some View {
        let size = Self.size(kind, phase: phase)
        Group {
            if case .failed = phase {
                Image(systemName: phase.symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoiceInk(isDark: isDark).ink).modifier(Halo(color: VoiceInk(isDark: isDark, inked: inked).halo))
            } else {
                switch kind {
                case .hex: hexVisualizer(phase: phase, loudness: loudness, isDark: isDark, reduceMotion: reduceMotion)
                case .wave: WaveVisualizer(phase: phase, loudness: loudness, isDark: isDark, reduceMotion: reduceMotion)
                case .ripple: RippleVisualizer(phase: phase, loudness: loudness, isDark: isDark, reduceMotion: reduceMotion)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true) // The drop's label says what it is doing.
    }
}

/// The drop's ink and halo, for marks drawn rather than typed: the same tones as its text, so a voice reads
/// over any backdrop with no backing shape. Increase Contrast's solid glass needs no halo, and neither does
/// ink that follows the backdrop (`BackdropInk`): it contrasts by itself, and a halo would be inked over too.
struct VoiceInk {
    let ink: Color, halo: Color
    init(isDark: Bool, increasedContrast: Bool = false, inked: Bool = false) {
        ink = isDark ? .white : Color(red: 0.06, green: 0.06, blue: 0.09)
        halo = increasedContrast || inked ? .clear : (isDark ? Color.black : .white).opacity(0.85)
    }
}
