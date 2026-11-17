import OopsCore
import SwiftUI

/// The Hex dot scope's place in `DictationVisualizerView`: the drop's state and its 0 to 1 loudness, turned
/// into the phase and the decibels the scope was built around.
func hexVisualizer(phase: DictationDropState, loudness: Float, live: (@MainActor () -> Float)? = nil, isDark: Bool,
                   reduceMotion: Bool) -> some View {
    var decibels: (@MainActor () -> Float)?
    if let live { decibels = { @MainActor in scopeDecibels(live()) } }
    return DotScopeView(phase: phase.scopePhase, loudness: scopeDecibels(loudness), liveLoudness: decibels, isDark: isDark,
                        reduceMotion: reduceMotion, tuning: scopeTuning)
}

/// The scope as wide as its drop, fading into the caps, in neutral greys: the drop's shape tells its state, so
/// the scope need not turn warm or cool. Its own levelling is off: the loudness it is given is levelled already,
/// and levelling again draws a shout no bigger than speech.
private let scopeTuning: DotScopeTuning = {
    var tuning = DotScopeTuning.bar(fade: 30, spacing: 3.2)
    tuning.autoLevel = false
    tuning.monochrome = true
    return tuning
}()

/// The scope's decibels, as its unlevelled mapping reads them (-40 silent to -10 full), on a curve that keeps
/// speech well below a shout. Silence still reads a little, so a listening scope breathes rather than goes flat.
private func scopeDecibels(_ level: Float) -> Float { -40 + 30 * (0.12 + 0.88 * pow(max(level, 0), 1.3)) }

private extension DictationDropState {
    var scopePhase: DotScopePhase {
        switch self {
        case .recording: .recording
        case .transcribing, .cleaningUp: .processing
        case .ready, .written, .failed, .kept, .copied: .failed
        }
    }
}
