@testable import OopsCore
import XCTest

/// The capture timeline and the silence gate, carried over from Hex's `src/dictation.rs` tests (1b82cc0).
final class DictationCaptureTests: XCTestCase {
    func testSilenceGateDiscardsOnlyNearSilentCaptures() {
        let clip = { (samples: [Float]) in DictationClip(samples: samples) }

        XCTAssertTrue(clip(repeated(0, 16_000)).isNearSilent)
        XCTAssertTrue(clip([]).isNearSilent)
        // A -66 dBFS noise floor and a constant DC offset carry no speech.
        XCTAssertTrue(clip(tone(0.000_7, 16_000)).isNearSilent)
        XCTAssertTrue(clip(repeated(0.2, 16_000)).isNearSilent)

        // 100 ms of whisper-level (-43 dBFS RMS) audio inside a second of silence is kept.
        let quietSpeech = clip(repeated(0, 8_000) + tone(0.01, 1_600) + repeated(0, 6_400))
        XCTAssertFalse(quietSpeech.isNearSilent)
        XCTAssertEqual(quietSpeech.loudestWindowDBFS(), -43, accuracy: 0.5)
        XCTAssertFalse(clip(tone(0.1, 16_000)).isNearSilent)
    }

    func testSilenceEvidenceSeparatesThePreRollFromAudioAfterThePress() throws {
        let silent = DictationClip(samples: repeated(0, 16_000)).silenceEvidence()
        XCTAssertEqual(silent.zeroFraction, 1)
        XCTAssertEqual(silent.peak, 0)

        // The press is handled 200 ms after it happened: the pre-roll still covers 450 ms before it, and
        // the timeline ran 200 ms past it.
        let origin = CaptureInstant(nanoseconds: 10_000_000_000)
        let press = try XCTUnwrap(origin.checkedSub(.milliseconds(200)))
        var capture = DictationCapture()
        capture.ingest(tone(0.1, 16_000), capturedThrough: origin)
        capture.startAt(press)
        capture.ingest(repeated(0, 8_000), capturedThrough: origin + .milliseconds(500))
        // 30 ms of audio never arrived.
        capture.ingest(repeated(0, 8_000), capturedThrough: origin + .milliseconds(1_030))
        let clip = try XCTUnwrap(capture.finish(origin + .milliseconds(1_000)).clip, "a held capture transcribes")

        XCTAssertEqual(clip.pressSamples, 7_200)
        XCTAssertEqual(clip.timeline.pressLeadMilliseconds, 200)
        XCTAssertEqual(clip.timeline.releaseLeadMilliseconds, 30)
        XCTAssertEqual(clip.timeline.maxChunkGap, .milliseconds(30))
        let evidence = clip.silenceEvidence()
        // A 0.1 sine is -23 dBFS RMS; the 200 ms after the press still carry it.
        XCTAssertEqual(evidence.prePressDBFS, -23, accuracy: 0.5)
        XCTAssertEqual(evidence.postPressDBFS, -23, accuracy: 0.5)
        XCTAssertGreaterThan(evidence.zeroFraction, 0.5)
        XCTAssertEqual(evidence.peak, 0.1, accuracy: 1e-3)
    }

    func testDelayedPressReconstructsAudioFromTheOriginalBoundary() throws {
        var capture = DictationCapture()
        let origin = captureTime()
        for index in 1 ... 16 {
            capture.ingest(repeated(Float(index), 1_600), capturedThrough: origin + .milliseconds(index * 100))
        }

        capture.startAt(origin + .seconds(1))
        for index in 17 ... 20 {
            capture.ingest(repeated(Float(index), 1_600), capturedThrough: origin + .milliseconds(index * 100))
        }

        let clip = try XCTUnwrap(capture.finish(origin + .milliseconds(1_800)).clip, "expected transcription")
        XCTAssertEqual(clip.durationMilliseconds, 1_250)
        XCTAssertEqual(clip.samples.first, 6)
    }

    func testAPressInsideALargeChunkKeepsExactlyThePreRoll() throws {
        // 500 ms chunks: the press is 300 ms past the newest audio, so 150 ms of it is kept and the rest
        // of the pre-roll arrives next.
        var chunk = Duration.milliseconds(500)
        var capture = DictationCapture()
        var through = ingestChunks(&capture, from: captureTime(), chunk: chunk, first: 1, count: 2)
        var pressed = through + .milliseconds(300)
        capture.start(at: pressed, preRoll: DictationCapture.readyPreRoll)
        XCTAssertEqual(capture.recordedFrom(0), repeated(2, 2_400))
        through = ingestChunks(&capture, from: through, chunk: chunk, first: 3, count: 2)
        var clip = try XCTUnwrap(capture.finish(through).clip, "expected transcription")
        XCTAssertEqual(clip.durationMilliseconds, 450 + 700)
        XCTAssertEqual(clip.pressSamples, 7_200)
        XCTAssertEqual(clip.samples.count { $0 == 2 }, 2_400)

        // 1 s chunks: the press is 800 ms past the newest audio, so nothing buffered is kept and the next
        // chunk loses its first 350 ms.
        chunk = .seconds(1)
        capture = DictationCapture()
        through = ingestChunks(&capture, from: captureTime(), chunk: chunk, first: 1, count: 1)
        pressed = through + .milliseconds(800)
        capture.start(at: pressed, preRoll: DictationCapture.readyPreRoll)
        XCTAssertTrue(capture.recordedFrom(0).isEmpty)
        _ = ingestChunks(&capture, from: through, chunk: chunk, first: 2, count: 2)
        clip = try XCTUnwrap(capture.finish(pressed + .seconds(1)).clip, "expected transcription")
        XCTAssertEqual(clip.durationMilliseconds, 450 + 1_000)
        XCTAssertEqual(clip.samples.first, 2)
        XCTAssertEqual(clip.samples.count { $0 == 2 }, 10_400)
    }

    // Hex derives the pre-roll from the recording environment (muting or ducking keeps none, doing nothing
    // keeps 450 ms); here the loop runs over the two pre-rolls that mapping yields.
    func testSuppressingAudioWhileDictatingKeepsNoPreRoll() throws {
        for (preRoll, kept) in [(Duration.zero, 0), (DictationCapture.readyPreRoll, 7_200)] {
            let origin = captureTime()
            var warm = DictationCapture()
            warm.ingest(repeated(0.25, 16_000), capturedThrough: origin)
            warm.startFromTimeline(origin, preRoll: preRoll)
            XCTAssertEqual(warm.recordedFrom(0).count, kept, "\(preRoll)")

            // A press 200 ms past the newest audio: with no pre-roll, the audio still to arrive before the
            // press is dropped too.
            var ahead = DictationCapture()
            ahead.ingest(repeated(0.25, 16_000), capturedThrough: origin)
            ahead.start(at: origin + .milliseconds(200), preRoll: preRoll)
            ahead.ingest(repeated(0.5, 8_000), capturedThrough: origin + .milliseconds(500))
            let clip = try XCTUnwrap(ahead.finish(origin + .milliseconds(500)).clip, "expected transcription")
            XCTAssertEqual(clip.pressSamples, kept, "\(preRoll)")
            XCTAssertEqual(clip.samples.count, kept + 4_800, "\(preRoll)")
        }
    }

    func testDelayedReleaseRemovesAudioCapturedAfterThePhysicalRelease() throws {
        var capture = DictationCapture()
        let origin = captureTime()
        capture.ingest(repeated(0.25, 16_000), capturedThrough: origin)
        capture.startAt(origin)
        for index in 1 ... 12 {
            capture.ingest(repeated(Float(index), 1_600), capturedThrough: origin + .milliseconds(index * 100))
        }

        let clip = try XCTUnwrap(capture.finish(origin + .seconds(1)).clip, "expected transcription")
        XCTAssertEqual(clip.durationMilliseconds, 1_450)
        XCTAssertFalse(clip.samples.contains(11))
        XCTAssertFalse(clip.samples.contains(12))
    }

    func testWarmBufferAcceptsChunksBeforeReachingCapacity() {
        var capture = DictationCapture()
        capture.keepWarm(repeated(0.25, 480))
        capture.keepWarm(repeated(0.5, 480))
        XCTAssertEqual(capture.ring.count, 960)
    }

    func testIntentionalHoldIncludesPreRollAndParakeetPadding() throws {
        var capture = DictationCapture()
        capture.keepWarm(repeated(0.25, 16_000))
        let start = captureTime()
        capture.start(start)
        capture.push(repeated(0.5, 8_000))
        let clip = try XCTUnwrap(capture.finish(start + .milliseconds(500)).clip, "expected transcription")
        XCTAssertEqual(clip.durationMilliseconds, 950)
        let samples = clip.paddedSamples
        XCTAssertEqual(samples.count, 24_000)
        XCTAssertEqual(samples[0], 0.25)
        XCTAssertTrue(samples.contains(0.5))
    }

    func testCaptureContinuesPastSixtySecondsUntilExplicitlyFinished() throws {
        var capture = DictationCapture()
        let start = captureTime()
        capture.start(start)
        capture.push(repeated(0.5, 61 * 16_000))

        let clip = try XCTUnwrap(capture.finish(start + .seconds(61)).clip, "expected transcription")
        XCTAssertEqual(clip.durationMilliseconds, 61_000)
    }
}
