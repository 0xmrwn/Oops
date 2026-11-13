import Foundation

// A finished recording and its silence gate, ported from Hex (github.com/anomalyco/hex, `src/dictation.rs`
// at 1b82cc0; MIT, Copyright (c) 2026 Christopher Langton): `DictationClip`, `loudest_window_dbfs`,
// `pad_for_parakeet`, and the evidence a discarded clip carries.

/// How the capture's audio lined up with its shortcut events.
struct ClipTimeline: Sendable, Equatable {
    /// How far the timeline ran past the press when the capture started; negative when audio had not yet
    /// reached the press.
    var pressLeadMilliseconds: Int64?
    /// How far the recorded audio ran past the release when it finished.
    var releaseLeadMilliseconds: Int64?
    /// The largest step between consecutive blocks.
    var maxChunkGap: Duration = .zero
}

/// What a near-silent clip measured, before and after the press.
struct SilenceEvidence: Sendable {
    var zeroFraction: Float
    var peak: Float
    var prePressDBFS: Float
    var postPressDBFS: Float
}

/// A finished recording: 16 kHz mono audio from the pre-roll through the release tail.
public struct DictationClip: Sendable {
    /// A capture whose loudest 30 ms window stays below this level is treated as empty rather than
    /// transcribed, because models hallucinate closing phrases such as "thank you" on silence. Deliberately
    /// conservative: whispered speech sits well above it, so only a quiet room's noise floor is discarded.
    public static let silenceThresholdDBFS: Float = -50
    static let silenceWindowSamples = 480
    /// The shortest audio a speech model is handed; shorter clips are padded with silence.
    public static let minimumModelDuration: Duration = .milliseconds(1500)

    let samples: [Float]
    /// How many trailing samples were captured after the release. A stop sound plays during them, so the
    /// silence gate ignores them.
    let tailSamples: Int
    /// How many leading samples were captured before the press.
    let pressSamples: Int
    let timeline: ClipTimeline

    init(samples: [Float], tailSamples: Int = 0, pressSamples: Int = 0, timeline: ClipTimeline = ClipTimeline()) {
        self.samples = samples; self.tailSamples = tailSamples; self.pressSamples = pressSamples; self.timeline = timeline
    }

    public var durationMilliseconds: Int { samples.count * 1_000 / DictationCapture.sampleRate }

    /// The captured audio through the release (before the tail and any model padding).
    var released: ArraySlice<Float> { samples[..<max(0, samples.count - tailSamples)] }

    /// The loudest 30 ms window's DC-removed RMS level in dBFS, over the captured audio through the release.
    func loudestWindowDBFS() -> Float { DictationClip.loudestWindowDBFS(released) }

    func silenceEvidence() -> SilenceEvidence {
        let released = released
        let split = released.startIndex + min(pressSamples, released.count)
        let zeros = released.count { $0 == 0 }
        return SilenceEvidence(zeroFraction: released.isEmpty ? 1 : Float(zeros) / Float(released.count),
                               peak: released.reduce(Float(0)) { max($0, abs($1)) },
                               prePressDBFS: Self.loudestWindowDBFS(released[..<split]),
                               postPressDBFS: Self.loudestWindowDBFS(released[split...]))
    }

    /// Whether every sample through the release is exactly zero. A real microphone always carries some
    /// noise, so this is a stream still running but delivering digital silence, not a quiet room.
    public var isDigitalSilence: Bool {
        let released = released
        return !released.isEmpty && released.allSatisfy { $0 == 0 }
    }

    /// Whether the capture holds no speech worth transcribing: its level stays below the silence threshold
    /// (a key click, a quiet room, or a microphone turned down too far). Such a capture writes nothing.
    public var isNearSilent: Bool { loudestWindowDBFS() < Self.silenceThresholdDBFS }

    /// The clip's audio, as captured.
    public var transcriptionSamples: [Float] { samples }

    /// The clip's audio padded with silence to `minimumModelDuration`.
    public var paddedSamples: [Float] {
        var samples = samples
        Self.padForMinimumModelDuration(&samples)
        return samples
    }

    /// Pads 16 kHz `samples` with silence to `minimumModelDuration`.
    public static func padForMinimumModelDuration(_ samples: inout [Float]) {
        let minimum = samplesFor(minimumModelDuration, sampleRate: DictationCapture.sampleRate)
        if samples.count < minimum { samples.append(contentsOf: repeatElement(0, count: minimum - samples.count)) }
    }

    static func loudestWindowDBFS(_ samples: ArraySlice<Float>) -> Float {
        var loudest = 0.0
        var start = samples.startIndex
        while start < samples.endIndex {
            let window = samples[start ..< min(start + silenceWindowSamples, samples.endIndex)]
            let count = Double(window.count)
            let mean = window.reduce(0.0) { $0 + Double($1) } / count
            let variance = window.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / count
            loudest = max(loudest, variance.squareRoot())
            start = window.endIndex
        }
        return Float(20 * log10(max(loudest, 1e-6)))
    }
}
