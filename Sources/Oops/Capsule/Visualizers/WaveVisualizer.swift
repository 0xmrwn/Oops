import OopsCore
import SwiftUI

/// The voice as it was heard, scrolling: the level now near the trailing end, and what was said sliding away from
/// it and fading into the leading cap, so the rhythm of speech shows. Silence is a faint row of dots that holds
/// still, with a breathing bar where the voice will land. Transcribing fades the bars out as a crest sweeps along
/// a centred row. Reduce Motion draws a calm hump whose height follows the voice.
struct WaveVisualizer: View {
    let phase: DictationDropState
    let loudness: Float
    let isDark: Bool
    let reduceMotion: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.voiceOnRegularGlass) private var onRegularGlass
    @State private var clock = VoiceClock()

    var body: some View {
        let ink = VoiceInk(isDark: isDark, increasedContrast: contrast == .increased, onRegularGlass: onRegularGlass)
        TimelineView(.animation(paused: reduceMotion || !phase.isLive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let frame = clock.frame(at: time, phase: phase, loudness: loudness, capacity: WaveDrawing.trail,
                                    interval: WaveDrawing.interval, holdsSilence: true, texture: true)
            Canvas { context, size in WaveDrawing.draw(frame, time: time, reduceMotion: reduceMotion, in: &context, size: size, ink: ink.ink) }
        }
        .modifier(Halo(color: ink.halo))
    }
}

enum WaveDrawing {
    /// The trail's samples (enough for the capsule's width) and the seconds each holds: a syllable to four or five bars.
    static let trail = 36, interval = 0.045
    /// A bar's width, which is also a dot's size, and the room each takes.
    static let bar: CGFloat = 2.5, pitch: CGFloat = 5
    /// How long transcribing takes to fade the heard bars out and the working row in.
    static let settle = 0.3

    static func draw(_ frame: WaveFrame, time: Double, reduceMotion: Bool, in context: inout GraphicsContext, size: CGSize, ink: Color) {
        let width = size.width, midX = width / 2, midY = size.height / 2, tallest = Double(midY - 7), dot = Double(bar / 2)
        // The ink's opacity, how much of the heard bars stays, how much of the working row shows, its clock, and whether levels count.
        let (opacity, keep, work, since, loud): (Double, Double, Double, Double, Double) = switch frame.mode {
        case .listening: (1, 1, 0, 0, 1)
        case .transcribing(let since):
            reduceMotion ? (0.75, 0, 1, 0, 1) : (1, 1 - VoiceMath.ease(since / settle), VoiceMath.ease(since / settle), since, 1)
        case .still: (0.7, 1, 0, 0, 0)
        }
        // The row fades into the leading cap; a still row is centred, so it fades into both.
        let shading = VoiceMath.shading(ink, reduceMotion ? [(0, 0), (0.2, 1), (0.8, 1), (1, 0)] : [(0, 0), (0.18, 1), (1, 1)], width: width)
        let breath = 0.5 + 0.5 * sin(2 * .pi * time / 1.6)

        // Each bar: where it sits, the level it shows, how far it has come out (or, ahead of the voice, how faint it is), and whether it is the live one.
        var marks: [(x: CGFloat, level: Double, gain: Double, live: Bool)] = []
        if reduceMotion {
            let half = Int((width - 44) / pitch) / 2
            for index in -half...half {
                let distance = Double(abs(index)) / Double(max(half, 1))
                marks.append((midX + CGFloat(index) * pitch, Double(frame.live) * (1 - 0.7 * distance * distance), 1, false))
            }
        } else {
            let lead = width - 24, progress = frame.history.progress
            // Two dots ahead of the voice, fading into the trailing cap: where the next sounds will land.
            marks += [(lead + pitch, 0, 0.55, false), (lead + 2 * pitch, 0, 0.25, false), (lead, Double(frame.live), 1, true)]
            for slot in 0..<frame.history.capacity {
                let x = lead - CGFloat(Double(slot) + progress) * pitch
                guard x > -pitch else { break }
                marks.append((x, Double(frame.history[slot]), slot == 0 ? min(progress * 3, 1) : 1, false))
            }
        }
        if keep > 0 {
            for mark in marks {
                let level = min(max(mark.level, 0), 1) * loud
                var half = dot + (tallest - dot) * pow(level, 1.15), alpha = 0.55 + 0.45 * pow(level, 0.5), barWidth = bar
                if mark.live {
                    barWidth = bar * 1.4
                    alpha = max(alpha, 0.9)
                    // With nothing heard, the live bar breathes, so the row never looks dead.
                    if loud > 0, level < 0.02 { (half, alpha) = (dot + 1.5 * breath, 0.6 + 0.4 * breath) }
                }
                context.opacity = opacity * alpha * mark.gain * keep
                let rect = CGRect(x: mark.x - barWidth / 2, y: midY - half * keep, width: barWidth, height: half * 2 * keep)
                context.fill(Capsule().path(in: rect), with: shading)
            }
        }
        guard work > 0 else { return }
        // A crest sweeps along a centred row, from the leading end to the trailing one, over and over.
        let fit = Int((width - 20) / pitch), count = max(fit - (fit + 1) % 2, 1)
        let centred = VoiceMath.shading(ink, [(0, 0), (0.15, 1), (0.85, 1), (1, 0)], width: width)
        for index in 0..<count {
            let x = midX + CGFloat(index - count / 2) * pitch
            let crest = pow(max(0, sin(2 * .pi * (1.1 * Double(x / width) - 1.3 * since))), 2)
            context.opacity = opacity * (0.55 + 0.45 * crest) * work
            let half = CGFloat(dot + 6.5 * crest)
            context.fill(Capsule().path(in: CGRect(x: x - bar / 2, y: midY - half, width: bar, height: half * 2)), with: centred)
        }
    }
}
