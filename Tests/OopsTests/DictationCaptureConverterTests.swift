@testable import Oops
@testable import OopsCore
import XCTest

/// The 16 kHz converter against the bar Hex's `StreamingResampler` and resampled captures set in
/// `src/dictation.rs` (1b82cc0).
final class DictationCaptureConverterTests: XCTestCase {
    private func convertWhole(_ samples: [Float], rate: Double) throws -> [Float] {
        let converter = try DictationAudioConverter(sourceRate: rate)
        return converter.push(samples) + converter.finish()
    }

    func testStreamingResamplerMatchesWholeBufferConversion() throws {
        for rate in [16_000, 44_100, 48_000] {
            let source = (0 ..< rate * 3 + 777).map { sin(Float($0) * 0.013) * 0.4 }
            let whole = try convertWhole(source, rate: Double(rate))
            let streaming = try DictationAudioConverter(sourceRate: Double(rate))
            var output: [Float] = []
            for start in stride(from: 0, to: source.count, by: 1_337) {
                output += streaming.push(Array(source[start ..< min(start + 1_337, source.count)]))
            }
            output += streaming.finish()
            XCTAssertEqual(output.count, whole.count, "rate \(rate)")
            XCTAssertTrue(zip(output, whole).allSatisfy { abs($0 - $1) < 1e-5 }, "rate \(rate)")
        }
    }

    func testRecordedAudioIsAPrefixOfTheFinishedClip() throws {
        for rate in [16_000, 44_100, 48_000] {
            let converter = try DictationAudioConverter(sourceRate: Double(rate))
            var capture = DictationCapture()
            let origin = CaptureInstant(nanoseconds: 1_000_000_000)
            capture.start(at: origin, preRoll: DictationCapture.readyPreRoll)
            let source = (0 ..< rate * 2).map { sin(Float($0) * 0.021) * 0.3 }
            var streamed: [Float] = []
            var through = origin
            for (index, start) in stride(from: 0, to: source.count, by: 480).enumerated() {
                through = origin + .nanoseconds(Int64((index + 1) * 480) * 1_000_000_000 / Int64(rate))
                let (samples, capturedThrough) = converter.push(Array(source[start ..< min(start + 480, source.count)]), capturedThrough: through)
                capture.ingest(samples, capturedThrough: capturedThrough)
                let recorded = capture.recording?.samples ?? []
                streamed += recorded[min(streamed.count, recorded.count)...]
            }
            // The end of the recording, flushed as the recorder does when its source ends.
            capture.ingest(converter.finish(), capturedThrough: converter.outputThrough(through))
            let finished = capture.finish(endedAt: origin + .seconds(5), tail: .zero)
            guard case let .transcribe(clip) = finished else { return XCTFail("a two-second hold transcribes") }
            let samples = clip.transcriptionSamples
            XCTAssertLessThanOrEqual(streamed.count, samples.count, "rate \(rate)")
            XCTAssertLessThan(samples.count - streamed.count, 1_024, "rate \(rate)")
            XCTAssertEqual(Array(samples[..<streamed.count]), streamed, "rate \(rate)")
        }
    }

    func testResamplingFlushesTheEndOfTheRecording() throws {
        for (rate, length) in [(44_100, 1_337), (44_100, 4_410), (48_000, 1_024), (48_000, 4_800)] {
            let samples = try convertWhole(repeated(0.5, length), rate: Double(rate))
            XCTAssertEqual(samples.count, length * 16_000 / rate, "\(rate) Hz, \(length)")
            XCTAssertGreaterThan(samples.last ?? 0, 0.25, "\(rate) Hz, \(length)")
        }
    }

    // Hex runs this with and without a live stream; Oops has no live stream, so only the clip is compared.
    func testResampledClipsKeepTheLastWordThroughADelayedRelease() throws {
        for rate in [44_100, 48_000] {
            let audio = pausedSpeech(rate)
            // Release 300 ms before the audio ends, inside the final word, after the block carrying that
            // audio and its tail has arrived.
            let releasedMs = audio.count * 1_000 / rate - 300
            let keptMs = releasedMs + 200
            let expected = try convertWhole(Array(audio[..<(keptMs * rate / 1_000)]), rate: Double(rate))
            let converter = try DictationAudioConverter(sourceRate: Double(rate))
            var capture = DictationCapture()
            let start = CaptureInstant(nanoseconds: 60_000_000_000)
            capture.start(at: start, preRoll: DictationCapture.readyPreRoll)
            var through = start
            for begin in stride(from: 0, to: audio.count, by: rate / 100) {
                through += .milliseconds(10)
                let (samples, capturedThrough) = converter.push(Array(audio[begin ..< min(begin + rate / 100, audio.count)]), capturedThrough: through)
                capture.ingest(samples, capturedThrough: capturedThrough)
            }
            guard case let .transcribe(clip) = capture.finish(endedAt: start + .milliseconds(releasedMs), tail: DictationCapture.postReleaseTail) else {
                return XCTFail("expected transcription")
            }
            let samples = clip.transcriptionSamples
            XCTAssertEqual(samples.count, expected.count, "\(rate) Hz")
            // Only the final 10 ms may differ: the clip's converter saw the real audio after the tail where
            // the reference saw silence.
            let settled = expected.count - 160
            XCTAssertTrue(zip(samples[..<settled], expected[..<settled]).allSatisfy { abs($0 - $1) < 1e-4 }, "\(rate) Hz lost audio before the tail ended")
        }
    }
}

func repeated(_ value: Float, _ count: Int) -> [Float] { [Float](repeating: value, count: count) }

/// Speech with pauses ending near 4.3 s and 9.3 s, at `rate`.
private func pausedSpeech(_ rate: Int) -> [Float] {
    let speech = utterance([(4_000, 1_000), (4_000, 1_000), (2_000, 0)], floorDB: -70)
    let ratio = 16_000 / Double(rate)
    return (0 ..< speech.count * rate / 16_000).map { frame in
        let position = Double(frame) * ratio
        let index = Int(position)
        let next = index + 1 < speech.count ? speech[index + 1] : speech[index]
        let fraction = Float(position - Double(index))
        return speech[index] * (1 - fraction) + next * fraction
    }
}

// From Hex's `src/transcription/pause_segmenter.rs` tests (1b82cc0).

/// Deterministic noise at a target RMS level in dBFS, 16 kHz.
private func noise(_ durationMs: Int, _ levelDB: Float, _ seed: inout UInt32) -> [Float] {
    let amplitude = powf(10, levelDB / 20) * sqrtf(3)
    return (0 ..< durationMs * 16).map { _ in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return amplitude * (Float(seed >> 8) / Float(1 << 24) * 2 - 1)
    }
}

/// Alternating speech and pauses: `(speechMs, pauseMs)`. Speech is syllable-like bursts separated by 60 ms
/// dips to the room level.
private func utterance(_ parts: [(Int, Int)], floorDB: Float) -> [Float] {
    var seed: UInt32 = 7
    var audio: [Float] = []
    func room(_ durationMs: Int) {
        if floorDB.isFinite { audio += noise(durationMs, floorDB, &seed) } else { audio += repeated(0, durationMs * 16) }
    }
    for (speech, pause) in parts {
        var remaining = speech
        while remaining > 0 {
            let burst = remaining <= 360 ? remaining : 240
            audio += noise(burst, -20, &seed)
            remaining -= burst
            if remaining > 0 {
                room(60)
                remaining -= 60
            }
        }
        room(pause)
    }
    return audio
}
