#if DEBUG
import AppKit
import OopsCore
import SwiftUI

/// Debug builds only: `-DictationVisualizerSnapshots <dir>` renders the Wave and Ripple visualizers in the lab's
/// stand-in drop at their moments (rest, speech, a peak, transcribing, Reduce Motion, a failure) over the lab's
/// three backdrops, one contact sheet per visualizer and appearance at 2×, then exits, so they can be judged
/// without taking the screen. Each moment is the synthetic voice played through the visualizer's own clock up
/// to that time. Glass renders flat here: the drop's lens blur only helps legibility on screen.
@MainActor enum DictationVisualizerSnapshots {
    private struct Moment {
        let name: String
        let time: Double
        /// When transcribing began, if it has.
        var transcribing: Double?
        var reduceMotion = false
        var failed = false
    }

    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let speech = loudest(in: 5.4...5.6), peak = loudest(in: 7.78...7.9)
        let moments = [
            Moment(name: "Rest", time: 1.9),
            Moment(name: "Speech", time: speech),
            Moment(name: "Between syllables", time: speech + 0.1),
            Moment(name: "Peak", time: peak),
            Moment(name: "Transcribing", time: 10.0, transcribing: 9.1),
            Moment(name: "Reduced speech", time: speech, reduceMotion: true),
            Moment(name: "Reduced transcribing", time: 10.0, transcribing: 9.1, reduceMotion: true),
            Moment(name: "Failed", time: 10.0, failed: true),
        ]
        for kind in [DictationVisualizer.wave, .ripple] {
            for dark in [false, true] {
                let sheet = VStack(alignment: .leading, spacing: 8) {
                    ForEach(moments.indices, id: \.self) { index in
                        row(kind, moments[index], dark: dark)
                    }
                }
                .padding(16).background(Color(white: dark ? 0.08 : 0.94))
                let renderer = ImageRenderer(content: sheet)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Visualizer render failed") }
                try? data.write(to: directory.appendingPathComponent("\(kind.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private static func row(_ kind: DictationVisualizer, _ moment: Moment, dark: Bool) -> some View {
        let state: DictationDropState = moment.failed ? .failed(.noMicrophone) : moment.transcribing == nil ? .recording : .transcribing
        return HStack(spacing: 8) {
            Text(moment.name).font(.system(size: 11, weight: .medium)).foregroundStyle(dark ? .white : .black).frame(width: 120, alignment: .leading)
            ForEach(LabBackdrop.allCases, id: \.self) { backdrop in
                ZStack(alignment: .bottomTrailing) {
                    backdrop.frame(width: 230, height: 92)
                    // Offscreen glass draws nothing, and an offscreen blur draws wrongly: the lens is stood in for by
                    // the backdrop without its text under the drop, as the lens's blur leaves of small text.
                    backdrop.plain.frame(width: 230, height: 92)
                        .mask(alignment: .bottomTrailing) {
                            Capsule().frame(width: LabDrop<EmptyView>.width(kind, state: state), height: EyesDropView.drop).padding(10)
                        }
                    LabDrop(kind: kind, state: state, dark: dark) { voice(kind, moment, state: state, dark: dark) }.padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder private static func voice(_ kind: DictationVisualizer, _ moment: Moment, state: DictationDropState, dark: Bool) -> some View {
        let ink = VoiceInk(isDark: dark)
        let size = DictationVisualizerView.size(kind, phase: state)
        if moment.failed {
            DictationVisualizerView(kind: kind, phase: state, loudness: 0, isDark: dark, reduceMotion: false)
        } else if kind == .wave {
            let frame = play(moment) { WaveClock() } frame: { $0.frame(at: $1, phase: $2, loudness: $3) }
            Canvas { context, size in WaveDrawing.draw(frame, reduceMotion: moment.reduceMotion, in: &context, size: size, ink: ink.ink) }
                .modifier(Halo(color: ink.halo)).frame(width: size.width, height: size.height)
        } else {
            let frame = play(moment) { RippleClock() } frame: { $0.frame(at: $1, phase: $2, loudness: $3) }
            Canvas { context, size in RippleDrawing.draw(frame, reduceMotion: moment.reduceMotion, in: &context, size: size, ink: ink.ink) }
                .modifier(RippleDrawing.Halo(color: ink.halo)).frame(width: size.width, height: size.height)
        }
    }

    /// The synthetic voice through a fresh clock at 120 frames a second, up to the moment.
    private static func play<Clock, Frame>(_ moment: Moment, clock make: () -> Clock,
                                           frame: (Clock, Double, DictationDropState, Float) -> Frame) -> Frame {
        let clock = make()
        var time = 0.0, last: Frame?
        while time <= moment.time {
            let transcribing = moment.transcribing.map { time >= $0 } ?? false
            last = frame(clock, time, transcribing ? .transcribing : .recording, transcribing ? 0 : SyntheticLoudness.level(at: time))
            time += 1.0 / 120
        }
        return last ?? frame(clock, moment.time, .recording, 0)
    }

    private static func loudest(in range: ClosedRange<Double>) -> Double {
        stride(from: range.lowerBound, through: range.upperBound, by: 1.0 / 120).max { SyntheticLoudness.level(at: $0) < SyntheticLoudness.level(at: $1) } ?? range.lowerBound
    }
}
#endif
