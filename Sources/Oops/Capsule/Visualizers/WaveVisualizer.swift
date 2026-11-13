import OopsCore
import SwiftUI

/// The last second of a voice as a row of short mirrored bars in the drop's ink: the newest at the trailing
/// edge, following the voice as it is heard, the rest gliding away and fading as they age, so the rhythm of
/// speech shows. Silence is a still row of dots. Transcribing lays the row down flat and a soft swell reads
/// along it, as if going over what was said. Reduce Motion keeps the bars in place: a calm hump whose height
/// follows the voice.
struct WaveVisualizer: View {
    let phase: DictationDropState
    let loudness: Float
    let isDark: Bool
    let reduceMotion: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.backdropInked) private var inked
    @State private var clock = WaveClock()

    var body: some View {
        let ink = VoiceInk(isDark: isDark, increasedContrast: contrast == .increased, inked: inked)
        // A failure draws once; Reduce Motion redraws only when the level changes.
        TimelineView(.animation(paused: reduceMotion || !phase.isLive)) { context in
            let frame = clock.frame(at: context.date.timeIntervalSinceReferenceDate, phase: phase, loudness: loudness)
            Canvas { context, size in WaveDrawing.draw(frame, reduceMotion: reduceMotion, in: &context, size: size, ink: ink.ink) }
        }
        .modifier(Halo(color: ink.halo))
    }
}

extension DictationDropState {
    /// Recording or transcribing: a voice to draw, moving.
    var isLive: Bool { if case .failed = self { false } else { true } }
}

/// What one frame of the wave draws: kept by value, so the canvas holds no reference into the clock.
struct WaveFrame {
    enum Mode: Equatable { case listening, transcribing(since: Double), still }
    var history: LoudnessHistory
    /// The level now, drawn at the trailing edge before it joins the history.
    var live: Float
    var mode: Mode
}

/// The wave's memory across frames. A recording starts from silence; transcribing freezes the row as it was.
@MainActor final class WaveClock {
    /// About a second of voice: syllables, spoken about five a second, each span two or three bars.
    static let bars = 14, interval = 0.07
    private var history = LoudnessHistory(capacity: bars, interval: interval)
    private var mode = WaveFrame.Mode.still

    func frame(at time: Double, phase: DictationDropState, loudness: Float) -> WaveFrame {
        switch phase {
        case .recording:
            if mode != .listening { history.reset(); mode = .listening }
            // Silence holds still: nothing to scroll, and the row of dots stays put.
            if loudness > 0 || !history.isSilent { history.advance(to: time, level: loudness) }
            return WaveFrame(history: history, live: loudness, mode: .listening)
        case .transcribing:
            if case .transcribing = mode {} else { mode = .transcribing(since: time) }
            return WaveFrame(history: history, live: 0, mode: mode.since(time))
        case .failed:
            mode = .still
            return WaveFrame(history: history, live: 0, mode: .still)
        }
    }
}

private extension WaveFrame.Mode {
    /// Seconds since transcribing began, as the drawing wants them.
    func since(_ time: Double) -> Self { if case .transcribing(let start) = self { .transcribing(since: time - start) } else { self } }
}

enum WaveDrawing {
    /// Bar width (and a dot's size), and the opacity the oldest bar keeps.
    static let bar: CGFloat = 2.5, oldest = 0.45
    /// How long transcribing takes to lay the row down, and one pass of its swell, pause included.
    static let settle = 0.35, sweep = 1.7

    static func draw(_ frame: WaveFrame, reduceMotion: Bool, in context: inout GraphicsContext, size: CGSize, ink: Color) {
        let count = frame.history.capacity, pitch = size.width / CGFloat(count)
        let lead = size.width - pitch / 2
        func mark(_ x: CGFloat, _ level: Float, _ opacity: Double, height: CGFloat? = nil) {
            guard opacity > 0.01 else { return }
            let height = max(height ?? Self.height(level, size), bar)
            // A shout fills the strip and also weighs more, so it reads apart from ordinary speech at a glance.
            let width = bar * (1 + 0.5 * CGFloat(max(level - 0.75, 0) / 0.25))
            let rect = CGRect(x: x - width / 2, y: (size.height - height) / 2, width: width, height: height)
            context.fill(Capsule().path(in: rect), with: .color(ink.opacity(min(opacity, 1))))
        }
        func age(_ slot: Double) -> Double { 1 - (1 - oldest) * slot / Double(count - 1) }

        if reduceMotion {
            // Every other bar, in place: a hump that rises with the voice, or a low still swell while transcribing.
            for slot in stride(from: 0, to: count, by: 2) {
                let x = lead - CGFloat(slot) * pitch, across = CGFloat(slot) / CGFloat(count - 2) * 2 - 1
                switch frame.mode {
                case .listening: mark(x, frame.live * Float(1 - 0.6 * across * across), 0.95)
                case .transcribing: mark(x, 0, 0.75, height: bar + 4 * (1 + cos(across * .pi)) / 2)
                case .still: mark(x, 0, 0.7)
                }
            }
            return
        }

        switch frame.mode {
        case .listening, .still:
            let progress = frame.history.progress
            for slot in 0..<count {
                let place = Double(slot) + progress, x = lead - CGFloat(place) * pitch
                // The newest bar comes out from under the live one; the oldest fades as it leaves.
                let entering = slot == 0 ? min(progress * 3, 1) : 1
                let leaving = min(max(Double(x) / Double(pitch), 0), 1)
                mark(x, frame.history[slot], age(place) * entering * leaving)
            }
            mark(lead, frame.live, 1)
        case .transcribing(let since):
            // The row as it was, laid down flat, then a swell travelling along it from the oldest to the newest.
            let flat = ease(since / settle), into = since - settle
            let cycle = into.truncatingRemainder(dividingBy: sweep) / (sweep * 0.8)
            let crest = -0.15 + 1.3 * cycle
            for slot in 0..<count {
                let place = Double(slot) + frame.history.progress, x = lead - CGFloat(place) * pitch
                let from = height(frame.history[slot], size), along = 1 - Double(x) / Double(size.width)
                let swell = into > 0 && cycle <= 1 ? exp(-pow((1 - along - crest) / 0.13, 2)) * min(into / 0.3, 1) : 0
                let leaving = min(max(Double(x) / Double(pitch), 0), 1)
                mark(x, 0, (0.6 + 0.4 * swell) * leaving, height: from + (bar - from) * flat + 8 * swell)
            }
        }
    }

    /// A level as a bar's height: a dot at silence, the full strip at full scale. The curve lifts quiet speech
    /// clear of the dots while leaving room above ordinary speech for a shout.
    static func height(_ level: Float, _ size: CGSize) -> CGFloat {
        bar + (size.height - bar) * CGFloat(pow(min(max(level, 0), 1), 0.8))
    }

    private static func ease(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return 1 - pow(1 - x, 3)
    }
}
