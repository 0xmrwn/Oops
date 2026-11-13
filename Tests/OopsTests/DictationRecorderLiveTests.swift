@testable import Oops
import OopsCore
import XCTest

/// The recording as a stream reads it while the key is still held. A WAV file stands in for the microphone.
@MainActor final class DictationRecorderLiveTests: XCTestCase {
    private let origin = CaptureInstant(nanoseconds: 60_000_000_000)
    private static let never: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3_600)) }

    func testRecordedFromAnOffsetReturnsOnlyNewSamples() async throws {
        // At real-time pace, so the recording grows while it is read.
        let file = DictationAudioFile(url: try wavFile(float: DictationSessionRun.speech(), rate: 16_000), pace: .realTime)
        let recorder = DictationRecorder(source: file, keepAliveSleep: Self.never)
        let idle = await recorder.recorded(from: 0)
        XCTAssertEqual(idle, [], "nothing records yet")
        try await recorder.start()
        var first: [Float] = []
        let deadline = ContinuousClock.now + .seconds(2)
        while first.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            first = await recorder.recorded(from: 0)
        }
        XCTAssertFalse(first.isEmpty)
        try await Task.sleep(for: .milliseconds(60))
        let next = await recorder.recorded(from: first.count), all = await recorder.recorded(from: 0)
        XCTAssertFalse(next.isEmpty, "the recording grew")
        XCTAssertEqual(Array(all.prefix(first.count + next.count)), first + next)
        let past = await recorder.recorded(from: all.count + 16_000)
        XCTAssertEqual(past, [])
        await recorder.cancel(closingSource: true)
        let cancelled = await recorder.recorded(from: 0)
        XCTAssertEqual(cancelled, [])
    }

    func testRecordedSamplesArePrefixesOfTheFinalClip() async throws {
        let audio = DictationSessionRun.speech()
        let file = DictationAudioFile(url: try wavFile(float: audio, rate: 16_000), pace: .immediate(from: origin))
        let recorder = DictationRecorder(source: file, keepAliveSleep: Self.never)
        try await recorder.start(at: origin + .milliseconds(400))
        var reads: [[Float]] = []
        for _ in 0 ..< 5 {
            reads.append(await recorder.recorded(from: 0))
            try await Task.sleep(for: .milliseconds(5))
        }
        // Released at the file's end, so the clip keeps everything the reads saw: the file from the press on.
        guard case let .samples(clip) = await recorder.stop(at: origin + .milliseconds(3_000)) else { return XCTFail("expected samples") }
        XCTAssertGreaterThan(clip.count, 40_000)
        XCTAssertTrue(clip == Array(audio[6_400...].prefix(clip.count)))
        for read in reads { XCTAssertTrue(read == Array(clip.prefix(read.count)), "\(read.count) of \(clip.count)") }
    }
}
