import OopsCore
import SwiftUI

/// A voice as rings on water, in the drop's cap where Fix keeps its eyes: a small core breathes slowly at
/// silence, swells with the level, and each syllable's onset sends out a ring whose weight and reach follow
/// how loud it was, so a shout carries to the rim and a murmur stays close. Transcribing settles the core and
/// sends one faint ring at a patient, even pace. Reduce Motion sends nothing out: the core and one still ring
/// grow and shrink with the voice.
struct RippleVisualizer: View {
    let phase: DictationDropState
    let loudness: Float
    let isDark: Bool
    let reduceMotion: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var clock = RippleClock()

    var body: some View {
        let ink = VoiceInk(isDark: isDark, increasedContrast: contrast == .increased)
        TimelineView(.animation(paused: reduceMotion || !phase.isLive)) { context in
            let frame = clock.frame(at: context.date.timeIntervalSinceReferenceDate, phase: phase, loudness: loudness)
            Canvas { context, size in RippleDrawing.draw(frame, reduceMotion: reduceMotion, in: &context, size: size, ink: ink.ink) }
        }
        .modifier(RippleDrawing.Halo(color: ink.halo))
    }
}

/// What one frame of the ripple draws, by value.
struct RippleFrame {
    var rings: [RippleEmitter.Ring]
    var time: Double
    var live: Float
    var mode: WaveFrame.Mode
}

/// The ripple's rings across frames; a recording starts with none.
@MainActor final class RippleClock {
    private var emitter = RippleEmitter()
    private var mode = WaveFrame.Mode.still

    func frame(at time: Double, phase: DictationDropState, loudness: Float) -> RippleFrame {
        switch phase {
        case .recording:
            if mode != .listening { emitter.reset(); mode = .listening }
            emitter.step(time: time, level: loudness)
            return RippleFrame(rings: emitter.rings, time: time, live: loudness, mode: .listening)
        case .transcribing:
            if case .transcribing = mode {} else { mode = .transcribing(since: time) }
            // Rings already out finish their way; no new ones.
            emitter.step(time: time, level: 0)
            guard case .transcribing(let start) = mode else { return RippleFrame(rings: [], time: time, live: 0, mode: .still) }
            return RippleFrame(rings: emitter.rings, time: time, live: 0, mode: .transcribing(since: time - start))
        case .failed:
            mode = .still
            return RippleFrame(rings: [], time: time, live: 0, mode: .still)
        }
    }
}

enum RippleDrawing {
    /// The core's radius at silence, and how much it swells at full scale.
    static let core: CGFloat = 3.5, swell: CGFloat = 3

    /// The drop's halo without its widest falloff, which would fill the water between rings and blur them into
    /// one disc.
    struct Halo: ViewModifier {
        let color: Color
        func body(content: Content) -> some View {
            content.shadow(color: color, radius: 0.5).shadow(color: color.opacity(0.85), radius: 1.4).shadow(color: color.opacity(0.35), radius: 3)
        }
    }

    /// One transcribing ring's lifetime, gap included.
    static let patience = 1.6

    static func draw(_ frame: RippleFrame, reduceMotion: Bool, in context: inout GraphicsContext, size: CGSize, ink: Color) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2), rim = min(size.width, size.height) / 2 - 1
        let level = CGFloat(pow(min(max(frame.live, 0), 1), 0.8))
        func disc(_ radius: CGFloat, _ opacity: Double) {
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Circle().path(in: rect), with: .color(ink.opacity(opacity)))
        }
        func ring(_ radius: CGFloat, width: CGFloat, _ opacity: Double) {
            guard opacity > 0.01 else { return }
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Circle().path(in: rect), with: .color(ink.opacity(min(opacity, 1))), lineWidth: width)
        }

        if reduceMotion {
            switch frame.mode {
            case .listening:
                disc(core + swell * level, 1)
                ring(core + swell * level + 3 + (rim - core - swell - 4) * level, width: 1.2, 0.3 + 0.5 * Double(level))
            case .transcribing:
                disc(core * 0.85, 0.85)
                ring(rim * 0.6, width: 1, 0.35)
            case .still: disc(core, 0.7)
            }
            return
        }

        for born in frame.rings {
            let amplitude = CGFloat(born.amplitude), age = (frame.time - born.born) / RippleEmitter.lifetime
            let spread = 1 - pow(1 - age, 2.2)
            // It leaves the core's edge as the onset swelled it, and a loud onset carries further: a shout to
            // the drop's rim, a murmur a little past the core.
            let leaves = core + swell * pow(amplitude, 0.8) + 1
            let reach = leaves + (rim - leaves) * (0.3 + 0.7 * pow(amplitude, 1.2))
            ring(leaves + (reach - leaves) * spread, width: (0.8 + 1.4 * amplitude) * (1 - 0.4 * age),
                 pow(1 - age, 1.4) * (0.45 + 0.55 * Double(amplitude)))
        }

        switch frame.mode {
        case .listening:
            // A slow breath at rest, about one every three seconds, smaller than any sound would make it.
            let breath = 0.3 * sin(frame.time * 2 * .pi / 3.2)
            disc(core + CGFloat(breath) * (1 - level) + swell * level, 1)
        case .transcribing(let since):
            let settle = min(since / 0.3, 1)
            disc(core * (1 - 0.15 * settle), 0.85 + 0.15 * (1 - settle))
            let age = since.truncatingRemainder(dividingBy: patience) / (patience * 0.85)
            if age <= 1 {
                let spread = 1 - pow(1 - age, 2)
                ring(core + (rim * 0.75 - core) * spread, width: 1.1, sin(age * .pi) * 0.5 * settle)
            }
        case .still: disc(core, 0.7)
        }
    }
}
