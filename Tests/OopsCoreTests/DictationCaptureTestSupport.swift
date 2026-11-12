import Foundation
@testable import OopsCore
import XCTest

// Helpers of Hex's `src/dictation.rs` tests (1b82cc0), for the capture tests carried over from it.

extension DictationCapture {
    /// Starts with the ready pre-roll from whatever the timeline holds, as Hex's `start`.
    mutating func start(_ now: CaptureInstant) { startWithPreRoll(now, duration: Self.readyPreRoll) }

    /// Starts at a press at or behind the newest audio with the ready pre-roll, as Hex's `start_at`.
    mutating func startAt(_ occurredAt: CaptureInstant) { startFromTimeline(occurredAt, preRoll: Self.readyPreRoll) }

    /// Adds audio to the recording without moving the timeline.
    mutating func push(_ samples: [Float]) { recording?.push(samples[...]) }

    mutating func keepWarm(_ samples: [Float]) { keepWarm(samples[...], retention: Self.timelineBufferDuration) }

    mutating func finish(_ endedAt: CaptureInstant) -> Finish { finish(endedAt: endedAt, tail: .zero) }

    /// 16 kHz audio recorded so far, from `start`.
    func recordedFrom(_ start: Int) -> [Float] {
        guard let samples = recording?.samples else { return [] }
        return Array(samples[min(start, samples.count)...])
    }
}

extension DictationCapture.Finish {
    var clip: DictationClip? { if case let .transcribe(clip) = self { clip } else { nil } }
}

func tone(_ amplitude: Float, _ samples: Int) -> [Float] {
    (0 ..< samples).map { amplitude * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
}

func repeated(_ value: Float, _ count: Int) -> [Float] { [Float](repeating: value, count: count) }

func captureTime() -> CaptureInstant { CaptureInstant(nanoseconds: 60_000_000_000) }

/// Ingests `count` chunks of `chunk` length after `from`, chunk `n` filled with `first + n`; returns the end of the last.
func ingestChunks(_ capture: inout DictationCapture, from: CaptureInstant, chunk: Duration, first: Int, count: Int) -> CaptureInstant {
    var through = from
    for index in 0 ..< count {
        through += chunk
        capture.ingest(repeated(Float(first + index), samplesFor(chunk, sampleRate: 16_000)), capturedThrough: through)
    }
    return through
}

/// Records `sound(ms)` (milliseconds from the release, which is 1 s after the press) in 20 ms chunks and
/// asks for the release tail after each one, as a capture loop does. Returns the tail it settled on, where
/// the audio had reached when it did, and the finished clip.
func releaseTailFor(_ sound: (Double) -> Float, stopTone: Duration, file: StaticString = #filePath,
                    line: UInt = #line) throws -> (tail: Duration, waited: Duration, clip: DictationClip) {
    var capture = DictationCapture()
    let origin = captureTime()
    capture.ingest(repeated(0, 16_000), capturedThrough: origin)
    capture.startAt(origin)
    let released = origin + .seconds(1)
    for chunk in 1 ... 100 {
        let start = (chunk - 1) * 320
        let samples = (start ..< start + 320).map { sound(Double($0) / 16 - 1_000) }
        let through = origin + .milliseconds(chunk * 20)
        capture.ingest(samples, capturedThrough: through)
        if through < released { continue }
        switch capture.releaseTail(endedAt: released, tone: stopTone) {
        case let .waiting(growing):
            XCTAssert(growing || through < released + DictationCapture.postReleaseTail, "the base tail waits for its own audio only", file: file, line: line)
        case let .through(tail):
            let clip = try XCTUnwrap(capture.finish(endedAt: released, tail: tail).clip, "expected transcription", file: file, line: line)
            return (tail, through.duration(since: released), clip)
        }
    }
    XCTFail("the tail never settled", file: file, line: line)
    throw CancellationError()
}

/// A 180 Hz voice at -13 dBFS between `from` and `to` ms.
func voice(_ from: Double, _ to: Double) -> (Double) -> Float {
    { ms in (from ..< to).contains(ms) ? 0.3 * Float(sin(2 * Double.pi * 180 * ms / 1_000)) : 0 }
}
