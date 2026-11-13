@testable import OopsCore
import XCTest

/// The release tail, carried over from Hex's `src/dictation.rs` tests (1b82cc0).
final class DictationCaptureTailTests: XCTestCase {
    func testReleaseTailKeepsAudioThroughTheTailAndNoFurther() throws {
        var capture = DictationCapture()
        let origin = captureTime()
        capture.ingest(repeated(0.25, 16_000), capturedThrough: origin)
        capture.startAt(origin)
        for index in 1 ... 14 {
            capture.ingest(repeated(Float(index), 1_600), capturedThrough: origin + .milliseconds(index * 100))
        }

        let clip = try XCTUnwrap(capture.finish(endedAt: origin + .seconds(1), tail: DictationCapture.postReleaseTail).clip, "expected transcription")
        XCTAssertEqual(clip.durationMilliseconds, 1_650)
        XCTAssertEqual(clip.samples.last, 12)
        XCTAssertFalse(clip.samples.contains(13))
        XCTAssertEqual(clip.tailSamples, 3_200)
    }

    func testAWordSaidThroughTheReleaseKeepsTheTailOpenUntilItEnds() throws {
        // The last word ran 350 ms past the release.
        let (tail, waited, clip) = try releaseTailFor(voice(-800, 350), stopTone: .zero)
        XCTAssertTrue((Duration.milliseconds(500) ... .milliseconds(540)).contains(tail), "\(tail)")
        XCTAssertLessThanOrEqual(waited, tail + .milliseconds(40), "\(waited)")
        // The whole word is in the clip: 450 ms pre-roll, 1 s, then the tail.
        let wordEnd = (450 + 1_000 + 340) * 16
        XCTAssertGreaterThan(clip.samples.count, wordEnd)
        XCTAssertTrue(clip.samples[wordEnd - 320 ..< wordEnd].contains { abs($0) > 0.1 })
    }

    func testAReleaseAfterTheSpeechKeepsTheBaseTailWithoutWaitingLonger() throws {
        let (tail, waited, clip) = try releaseTailFor(voice(-800, -60), stopTone: .zero)
        XCTAssertEqual(tail, DictationCapture.postReleaseTail)
        XCTAssertEqual(waited, DictationCapture.postReleaseTail)
        XCTAssertEqual(clip.durationMilliseconds, 1_650)
    }

    func testSpeechThatCarriesOnStopsTheTailAtItsCap() throws {
        let (tail, waited, clip) = try releaseTailFor(voice(-800, 5_000), stopTone: .zero)
        XCTAssertEqual(tail, DictationCapture.maxReleaseTail)
        XCTAssertEqual(waited, DictationCapture.maxReleaseTail)
        XCTAssertEqual(clip.durationMilliseconds, 2_050)
    }

    func testTheStopToneOrAKeyClickNeverGrowsTheTail() throws {
        let speech = voice(-800, -60)
        // A 225 ms stop sound, loud and late through the output.
        let stopTone = Duration.milliseconds(225)
        let withTone = { (ms: Double) -> Float in
            var tone: Float = 0
            if (30 ..< 255).contains(ms) {
                let decay = 1 - (ms - 30) / 225
                tone = Float(0.4 * decay * sin(2 * Double.pi * 880 * ms / 1_000))
            }
            return speech(ms) + tone
        }
        var (tail, waited, _) = try releaseTailFor(withTone, stopTone: stopTone)
        XCTAssertEqual(tail, DictationCapture.postReleaseTail)
        // A key click: 15 ms of noise right at the end of the base tail.
        let withClick = { (ms: Double) -> Float in
            let click: Float = (185 ..< 200).contains(ms) ? (Int64(ms * 16).isMultiple(of: 2) ? 0.8 : -0.8) : 0
            return speech(ms) + click
        }
        (tail, waited, _) = try releaseTailFor(withClick, stopTone: stopTone)
        XCTAssertEqual(tail, DictationCapture.postReleaseTail)
        XCTAssertEqual(waited, DictationCapture.postReleaseTail)
        // Speech still going once the tone is over does grow the tail.
        let later = voice(150, 450)
        (tail, _, _) = try releaseTailFor({ withTone($0) + later($0) }, stopTone: stopTone)
        XCTAssertGreaterThan(tail, .milliseconds(450), "\(tail)")
    }

    func testTheStopToneInTheTailDoesNotMakeSilenceTranscribe() throws {
        var capture = DictationCapture()
        let origin = captureTime()
        capture.startAt(origin)
        let released = origin + .seconds(1)
        capture.ingest(repeated(0, 16_000), capturedThrough: released)
        capture.ingest(tone(0.1, 3_200), capturedThrough: released + DictationCapture.postReleaseTail)
        let clip = try XCTUnwrap(capture.finish(endedAt: released, tail: DictationCapture.postReleaseTail).clip, "expected transcription")
        XCTAssertEqual(clip.durationMilliseconds, 1_200)
        XCTAssertTrue(clip.isNearSilent)
    }
}
