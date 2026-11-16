@testable import Oops
import OopsCore
import Synchronization
import XCTest

/// "Keep the microphone ready": the source stays open between recordings, and a press keeps the audio from just
/// before it. A WAV file stands in for the microphone; nothing here opens it or asks for access.
final class DictationRecorderPreRollTests: XCTestCase {
    private let origin = CaptureInstant(nanoseconds: 60_000_000_000)

    func testAReadyMicrophoneStartsTheCaptureWithTheAudioFromBeforeThePress() async throws {
        let audio = speech()
        for ready in [true, false] {
            let suite = try settings(keepReady: ready).suite
            let source = HeldFileSource(try wavFile(float: audio, rate: 16_000), from: origin)
            // As the app reads it at each press; a suite is read afresh, since the defaults object may not cross over.
            let preRoll: @Sendable () -> Duration = { DictationAudioSettings.pressPreRoll(UserDefaults(suiteName: suite) ?? .standard) }
            let recorder = DictationRecorder(source: source, preRoll: preRoll, keepAliveSleep: Self.never)
            await recorder.keepReady(ready)
            let openBeforePress = await recorder.isSourceOpen
            XCTAssertEqual(openBeforePress, ready)

            // The word starts at 500 ms; the press comes at 800 ms, the release at 1.6 s, 100 ms after it ends.
            try await recorder.start(at: origin + .milliseconds(800))
            let outcome = await recorder.stop(at: origin + .milliseconds(1_600))
            // Ready, the clip opens 450 ms before the press, on the start of the word; otherwise on the press.
            let from = ready ? 5_600 : 12_800
            XCTAssertEqual(outcome, .samples(Array(audio[from ..< 28_800])), "ready \(ready)")
            XCTAssertEqual(source.counts.opens, 1, "ready \(ready)")
        }
    }

    func testAReadyMicrophoneStaysOpenBetweenRecordingsAndClosesWhenNoLongerWanted() async throws {
        let source = HeldFileSource(try wavFile(float: speech(), rate: 16_000), from: origin)
        let sleeps = HeldSleeps()
        let recorder = DictationRecorder(source: source, preRoll: { DictationAudioSettings.preRoll }, keepAliveSleep: sleeps.sleep)
        await recorder.keepReady(true)
        for _ in 0 ..< 2 {
            try await recorder.start(at: origin + .milliseconds(800))
            _ = await recorder.stop(at: origin + .milliseconds(1_600))
            let open = await recorder.isSourceOpen
            XCTAssertTrue(open)
        }
        // A cancel that asks for silence drops the recording, not the ready microphone.
        try await recorder.start(at: origin + .milliseconds(800))
        await recorder.cancel(closingSource: true)
        let openAfterCancel = await recorder.isSourceOpen
        XCTAssertTrue(openAfterCancel)
        XCTAssertTrue(sleeps.durations.isEmpty, "no keep-alive counts down while ready")
        XCTAssertEqual(source.counts.opens, 1)

        await recorder.keepReady(false)
        let openAfterOff = await recorder.isSourceOpen
        XCTAssertFalse(openAfterOff)
        XCTAssertEqual(source.counts.closes, 1)
    }

    func testTurnedOffMidRecordingTheMicrophoneClosesAfterTheKeepAliveWithinThirtySeconds() async throws {
        // Off, the indicator goes once the keep-alive after a dictation runs out.
        XCTAssertLessThan(DictationRecorder.keepAlive, .seconds(30))
        let source = HeldFileSource(try wavFile(float: speech(), rate: 16_000), from: origin)
        let sleeps = HeldSleeps()
        let recorder = DictationRecorder(source: source, keepAliveSleep: sleeps.sleep)
        await recorder.keepReady(true)
        try await recorder.start(at: origin + .milliseconds(800))
        await recorder.keepReady(false)
        let openWhileRecording = await recorder.isSourceOpen
        XCTAssertTrue(openWhileRecording, "the recording keeps its microphone")
        _ = await recorder.stop(at: origin + .milliseconds(1_600))
        try await sleeps.waitForSleepers(1)
        XCTAssertEqual(sleeps.durations, [DictationRecorder.keepAlive])
        sleeps.release(0)
        try await eventually { await !recorder.isSourceOpen }
    }

    func testWithoutMicrophoneAccessAReadyMicrophoneOpensNothingAndAsksNothing() async {
        for access in [DictationMicrophoneAccess.denied, .undetermined] {
            let recorder = DictationRecorder(source: DictationMicrophone(access: { access }), keepAliveSleep: Self.never)
            await recorder.keepReady(true)
            let open = await recorder.isSourceOpen
            XCTAssertFalse(open, "\(access)")
        }
    }

    @MainActor func testReadinessFollowsTheSettingAndTheShortcut() async throws {
        let defaults = try settings(keepReady: false).defaults
        let recorder = DictationRecorder(source: HeldFileSource(try wavFile(float: speech(), rate: 16_000), from: origin), keepAliveSleep: Self.never)
        var hasShortcut = true
        let readiness = DictationReadiness(recorder: recorder, defaults: defaults) {
            DictationAudioSettings.keepReady(defaults) && hasShortcut
        }
        await readiness.settled()
        var open = await recorder.isSourceOpen
        XCTAssertFalse(open)

        defaults.set(true, forKey: DictationAudioSettings.keepReadyKey)
        try await eventually { await recorder.isSourceOpen }
        // The shortcut goes: its removal is saved to the defaults too.
        hasShortcut = false
        defaults.set(Data(), forKey: "Shortcut.dictate.test")
        try await eventually { await !recorder.isSourceOpen }
        hasShortcut = true
        readiness.apply()
        await readiness.settled()
        open = await recorder.isSourceOpen
        XCTAssertTrue(open)
    }

    // MARK: - Support

    private static let never: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3_600)) }

    /// 0.5 s of silence, 1 s of a 180 Hz voice at -13 dBFS, then 1.5 s of silence, at 16 kHz.
    private func speech() -> [Float] {
        (0 ..< 48_000).map { index in
            let seconds = Double(index) / 16_000
            return (0.5 ..< 1.5).contains(seconds) ? 0.3 * Float(sin(2 * Double.pi * 180 * seconds)) : 0
        }
    }

    private func settings(keepReady: Bool) throws -> (defaults: UserDefaults, suite: String) {
        let suite = "DictationRecorderPreRollTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(keepReady, forKey: DictationAudioSettings.keepReadyKey)
        return (defaults, suite)
    }

    private nonisolated(nonsending) func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A microphone that has heard a WAV file by the time it opens, stamped from `from`, and keeps running: what an
/// open microphone holds when the press comes. Counts its opens and closes.
private final class HeldFileSource: DictationAudioSource {
    private let url: URL
    private let from: CaptureInstant
    private let state = Mutex((opens: 0, closes: 0))

    init(_ url: URL, from: CaptureInstant) { self.url = url; self.from = from }

    var counts: (opens: Int, closes: Int) { state.withLock { $0 } }

    func open(into ring: DictationAudioRing) throws(DictationAudioError) -> Double {
        state.withLock { $0.opens += 1 }
        let (samples, rate) = try DictationAudioFile.read(url)
        let block = Int(rate) / DictationAudioFile.blocksPerSecond
        for start in stride(from: 0, to: samples.count, by: block) {
            let end = min(start + block, samples.count)
            let through = from + .nanoseconds(Int64(end) * 1_000_000_000 / Int64(rate))
            ring.write(frames: end - start, capturedThrough: through) { samples[start + $0] }
        }
        return rate
    }

    func close() { state.withLock { $0.closes += 1 } }
}
