import OopsCore
import SwiftUI

extension DictationDropState {
    /// Recording, or work under way on what was said: a voice to draw, moving.
    var isLive: Bool {
        switch self {
        case .recording, .transcribing, .cleaningUp: true
        case .ready, .written, .failed, .kept, .copied: false
        }
    }
}

/// What one frame of a drawn voice shows: kept by value, so the canvas holds no reference into the clock.
struct WaveFrame {
    enum Mode: Equatable { case listening, transcribing(since: Double), still }
    var history: LoudnessHistory
    /// The level now, drawn ahead of the history; while transcribing, the last level heard.
    var live: Float
    var mode: Mode
}

/// The memory the drawn voices share across frames: a recording starts from silence, and transcribing (or
/// cleaning up, the same work to the eye) freezes the history and the last level heard, so the drawing can
/// ease from where the voice was.
@MainActor final class VoiceClock {
    private var history = LoudnessHistory(capacity: 1, interval: 1)
    private var mode = WaveFrame.Mode.still
    private var heard: Float = 0

    /// `holdsSilence` stops the history advancing while nothing is heard, so a scrolling row stays put.
    /// `texture` varies each sample's loudness a little, so a sustained loud passage is not a block of equal bars.
    func frame(at time: Double, phase: DictationDropState, loudness: Float, capacity: Int, interval: Double,
               holdsSilence: Bool = false, texture: Bool = false) -> WaveFrame {
        if history.capacity != capacity { history = LoudnessHistory(capacity: capacity, interval: interval); mode = .still }
        switch phase {
        case .recording:
            if mode != .listening { history.reset(); mode = .listening }
            let fed = texture ? loudness * Float(0.78 + 0.22 * VoiceMath.grain(Int((time / interval).rounded(.down)))) : loudness
            if !holdsSilence || loudness > 0 || !history.isSilent { history.advance(to: time, level: fed) }
            heard = loudness
            return WaveFrame(history: history, live: loudness, mode: .listening)
        case .transcribing, .cleaningUp:
            if case .transcribing = mode {} else { mode = .transcribing(since: time) }
            guard case .transcribing(let start) = mode else { return WaveFrame(history: history, live: 0, mode: .still) }
            return WaveFrame(history: history, live: heard, mode: .transcribing(since: time - start))
        case .ready, .written, .failed, .kept, .copied:
            mode = .still
            return WaveFrame(history: history, live: 0, mode: .still)
        }
    }
}

enum VoiceMath {
    /// The level `position` slots from the live one: the live level, then the history, shifted by its progress
    /// and eased between samples, so a drawing glides rather than steps.
    static func level(_ history: LoudnessHistory, _ live: Float, at position: Double) -> Double {
        let progress = history.progress, along = position - 1 - progress
        guard along >= 0 else { return blend(Double(live), Double(history[0]), position / (1 + progress)) }
        let slot = Int(along.rounded(.down))
        return blend(Double(history[slot]), Double(history[slot + 1]), along - Double(slot))
    }

    static func blend(_ from: Double, _ to: Double, _ x: Double) -> Double { from + (to - from) * smooth(0, 1, x) }

    static func smooth(_ low: Double, _ high: Double, _ x: Double) -> Double {
        let x = min(max((x - low) / (high - low), 0), 1)
        return x * x * (3 - 2 * x)
    }

    static func ease(_ x: Double) -> Double { 1 - pow(1 - min(max(x, 0), 1), 3) }

    /// A cheap deterministic hash of `n` in 0...1.
    static func grain(_ n: Int) -> Double {
        let x = sin(Double(n) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    /// A horizontal fade of the ink across `width`, from (location, opacity) stops.
    static func shading(_ ink: Color, _ stops: [(Double, Double)], width: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: stops.map { Gradient.Stop(color: ink.opacity($0.1), location: $0.0) }),
                        startPoint: .zero, endPoint: CGPoint(x: width, y: 0))
    }
}
