import OopsCore
import SwiftUI

/// The Hex dot scope's place in `DictationVisualizerView`: the drop's state and its 0 to 1 loudness, turned
/// into the phase and the decibels the scope was built around.
func hexVisualizer(phase: DictationDropState, loudness: Float, isDark: Bool, reduceMotion: Bool) -> some View {
    DotScopeView(phase: phase.scopePhase, loudness: scopeDecibels(loudness), isDark: isDark, reduceMotion: reduceMotion)
}

/// The scope levels itself from decibels, so the smoothed level goes back onto the range it was mapped from;
/// 0 reads as silence, below the scope's noise floor.
private func scopeDecibels(_ level: Float) -> Float {
    level <= 0 ? -80 : DictationLoudness.floorDBFS + level * (DictationLoudness.ceilingDBFS - DictationLoudness.floorDBFS)
}

private extension DictationDropState {
    var scopePhase: DotScopePhase {
        switch self {
        case .recording: .recording
        case .transcribing: .processing
        case .failed: .failed
        }
    }
}
