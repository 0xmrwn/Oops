import OopsCore
import SwiftUI

/// Five soft hairline strands across the capsule, in the drop's ink, sharing one envelope so they fan out from a
/// single line. The voice is heard at the centre and each syllable travels outward, spreading the strands apart;
/// silence leaves them nearly converged into one slowly shimmering line. Transcribing lets the voice drain away
/// into a steady, busier shimmer. Reduce Motion draws one still bow.
struct StringVisualizer: View {
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
            let frame = clock.frame(at: time, phase: phase, loudness: loudness, capacity: StringDrawing.slots, interval: StringDrawing.interval)
            Canvas { context, size in
                StringDrawing.draw(frame, time: time, reduceMotion: reduceMotion, in: &context, size: size, ink: ink.ink)
            }
        }
        .modifier(Halo(color: ink.halo))
    }
}

enum StringDrawing {
    /// Samples across half the capsule, and the seconds each holds: 0.8 s of voice, a syllable to a sample or two, so a
    /// swell is as long as a syllable and the strands stay smooth.
    static let slots = 10, interval = 0.08
    /// How long the voice takes to drain while the working shimmer swells in.
    static let settle = 0.3

    /// One strand's share of the envelope, cycles across the width, cycles a second, phase, line width and opacity.
    typealias Strand = (gain: Double, wave: Double, speed: Double, phase: Double, width: CGFloat, opacity: Double)
    /// Back to front, so the lightest are drawn first and the main strand sits on top. Unequal waves and speeds keep them from locking together.
    static let strands: [Strand] = [(0.72, 1.5, 0.45, 5.2, 0.8, 0.30), (0.90, 3.0, -0.60, 3.9, 0.8, 0.35), (0.64, 1.8, 0.70, 2.6, 1.0, 0.45),
                                    (0.82, 2.6, -0.40, 1.3, 1.0, 0.60), (1.00, 2.2, 0.55, 0.0, 1.6, 1.00)]

    static func draw(_ frame: WaveFrame, time: Double, reduceMotion: Bool, in context: inout GraphicsContext, size: CGSize, ink: Color) {
        let midY = size.height / 2, reach = Double(midY - 4), working = 0.32 * Double(midY), steps = max(Int(size.width / 1.5), 1)
        let us = (0...steps).map { Double($0) / Double(steps) }
        let windows = us.map { VoiceMath.smooth(0, 0.15, $0) * VoiceMath.smooth(0, 0.15, 1 - $0) }
        let shading = VoiceMath.shading(ink, [(0, 0), (0.12, 1), (0.88, 1), (1, 0)], width: size.width)
        let stroke = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round) }
        guard frame.mode != .still else {
            context.opacity = 0.7
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: midY)); $0.addLine(to: CGPoint(x: size.width, y: midY)) }, with: shading, style: stroke(1.6))
            return
        }

        // Blurred along the width: a syllable's 40 ms attack, and the fold at the centre, would otherwise kink the strands.
        func heard() -> [Double] {
            var levels = us.map { VoiceMath.level(frame.history, frame.live, at: abs($0 - 0.5) * 2 * Double(slots - 1)) }
            let radius = max(steps / 16, 1)
            for _ in 0..<3 {
                levels = levels.indices.map { index in
                    let near = max(index - radius, 0)...min(index + radius, steps)
                    return levels[near].reduce(0, +) / Double(near.count)
                }
            }
            // The blur takes the edge off speech: lifted back, so it fills about half the drop and a shout all of it.
            return levels.map { reach * pow(min(max(1.4 * $0, 0), 1), 1.1) }
        }
        let live = Double(frame.live), breath = 1.2 + 0.6 * sin(2 * .pi * time / 2.6)
        let voice = reduceMotion ? [] : heard()
        let e: Double = if case .transcribing(let since) = frame.mode { VoiceMath.ease(since / settle) } else { 0 }
        let (amps, opacity): ([Double], Double) = switch (frame.mode, reduceMotion) {
        case (.listening, true):
            (us.indices.map { windows[$0] * max(1.2, reach * pow(min(1.4 * live, 1), 1.1) * sin(.pi * us[$0])) }, 1)
        case (.transcribing, true): (windows.map { $0 * working }, 0.75)
        case (.listening, false): (us.indices.map { windows[$0] * max(breath, voice[$0]) }, 1)
        case (.transcribing, false): (us.indices.map { windows[$0] * (voice[$0] * (1 - e) + working * e) }, 1)
        case (.still, _): ([], 0.7)
        }

        // Working strands run faster than silent ones, so transcribing reads as busier rather than as silence.
        var t = reduceMotion ? 0 : time
        if case .transcribing = frame.mode { t *= 1.8 }
        for strand in strands {
            let path = Path { path in
                for (index, u) in us.enumerated() {
                    let y = midY + CGFloat(amps[index] * strand.gain * sin(2 * .pi * (strand.wave * u - strand.speed * t) + strand.phase))
                    let point = CGPoint(x: size.width * CGFloat(u), y: y)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            context.opacity = opacity * strand.opacity
            context.stroke(path, with: shading, style: stroke(strand.width))
        }
    }
}
