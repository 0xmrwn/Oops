@testable import Oops
import OopsCore
import Synchronization
import XCTest

/// The microphone's input changing (the default input, the inputs, the lid, a setting): the recorder applies the
/// change only between recordings, and a ready microphone comes back once an input is there. A WAV file stands in
/// for the microphone; nothing here opens it.
final class DictationRecorderInputChangeTests: XCTestCase {
    private let origin = CaptureInstant(nanoseconds: 60_000_000_000)

    func testAnInputChangeDuringARecordingWaitsForItToEnd() async throws {
        let source = ChangingSource(try speech(), from: origin)
        let recorder = DictationRecorder(source: source, keepAliveSleep: Self.never)
        await recorder.keepReady(true)
        try await recorder.start(at: origin + .milliseconds(800))
        source.stale = true
        source.change()
        // The change reaches the recorder, which leaves the recording's input alone.
        try await Task.sleep(for: .milliseconds(50))
        let recording = await recorder.isRecording
        XCTAssertTrue(recording)
        XCTAssertEqual(source.counts.follows, 0)
        let outcome = await recorder.stop(at: origin + .milliseconds(1_600))
        guard case .samples = outcome else { return XCTFail("\(outcome)") }
        // Applied once the recording ended: the source closed on the old input and, ready, opened on the new one.
        XCTAssertEqual(source.counts.follows, 1)
        XCTAssertEqual(source.counts.closes, 1)
        XCTAssertEqual(source.counts.opens, 2)
        let open = await recorder.isSourceOpen
        XCTAssertTrue(open)
    }

    func testAnInputChangeBetweenRecordingsClosesTheSourceUnlessKeptReady() async throws {
        for ready in [true, false] {
            let source = ChangingSource(try speech(), from: origin)
            let recorder = DictationRecorder(source: source, keepAliveSleep: Self.never)
            await recorder.keepReady(ready)
            try await recorder.start(at: origin + .milliseconds(800))
            _ = await recorder.stop(at: origin + .milliseconds(1_600))
            source.stale = true
            source.change()
            try await eventually { source.counts.closes == 1 }
            let open = await recorder.isSourceOpen
            XCTAssertEqual(open, ready, "ready \(ready)")
            XCTAssertEqual(source.counts.opens, ready ? 2 : 1, "ready \(ready)")
        }
    }

    func testOnlyAReadyMicrophoneSchedulesTheLookForAPickedMicrophoneThatWouldNotOpen() async throws {
        let url = try speech()
        let ready = ChangingSource(url, from: origin), pressed = ChangingSource(url, from: origin)
        await DictationRecorder(source: ready, keepAliveSleep: Self.never).keepReady(true)
        XCTAssertEqual(ready.counts.retries, 1)
        // Opened for one recording, the next open looks for the picked microphone anyway, as before.
        try await DictationRecorder(source: pressed, keepAliveSleep: Self.never).start(at: origin + .milliseconds(800))
        XCTAssertEqual(pressed.counts.retries, 0)
    }

    func testAReadyMicrophoneThatFoundNoInputOpensOnceOneArrives() async throws {
        for ready in [true, false] {
            let source = ChangingSource(try speech(), from: origin)
            source.missing = true
            let recorder = DictationRecorder(source: source, keepAliveSleep: Self.never)
            await recorder.keepReady(ready)
            if !ready { do { try await recorder.start() } catch {} }
            var open = await recorder.isSourceOpen
            XCTAssertFalse(open, "ready \(ready)")
            // A microphone is plugged in, or the lid opens.
            source.missing = false
            source.change()
            if ready { try await eventually { await recorder.isSourceOpen } } else { try await Task.sleep(for: .milliseconds(50)) }
            open = await recorder.isSourceOpen
            XCTAssertEqual(open, ready, "ready \(ready)")
            XCTAssertEqual(source.counts.opens, ready ? 1 : 0, "ready \(ready)")
        }
    }

    // MARK: - Support

    /// 0.5 s of silence, 1 s of a 180 Hz voice, then 1.5 s of silence, at 16 kHz.
    private func speech() throws -> URL {
        try wavFile(float: (0 ..< 48_000).map { index in
            let seconds = Double(index) / 16_000
            return (0.5 ..< 1.5).contains(seconds) ? 0.3 * Float(sin(2 * Double.pi * 180 * seconds)) : 0
        }, rate: 16_000)
    }

    private static let never: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3_600)) }

    private nonisolated(nonsending) func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A microphone that has heard a WAV file by the time it opens, stamped from `from`, and keeps running, with no audio
/// past the file's end. Its input can go missing, or change so that the next follow replaces it.
final class ChangingSource: DictationAudioSource {
    struct Counts { var opens = 0, closes = 0, follows = 0, retries = 0 }

    private let url: URL
    private let from: CaptureInstant
    private let state = Mutex((counts: Counts(), stale: false, missing: false, changed: (@Sendable () -> Void)?.none))

    init(_ url: URL, from: CaptureInstant) { self.url = url; self.from = from }

    var counts: Counts { state.withLock { $0.counts } }

    /// The next follow finds another input.
    var stale: Bool {
        get { state.withLock { $0.stale } }
        set { state.withLock { $0.stale = newValue } }
    }

    /// No microphone is there: opens fail.
    var missing: Bool {
        get { state.withLock { $0.missing } }
        set { state.withLock { $0.missing = newValue } }
    }

    /// The default input, the inputs or the lid changed.
    func change() { state.withLock { $0.changed }?() }

    func watchInputChange(_ changed: @escaping @Sendable () -> Void) { state.withLock { $0.changed = changed } }

    func followInputChange() -> Bool {
        state.withLock { state in
            defer { state.stale = false }
            state.counts.follows += 1
            return state.stale
        }
    }

    func scheduleFallbackRetry() { state.withLock { $0.counts.retries += 1 } }

    func open(into ring: DictationAudioRing) throws(DictationAudioError) -> Double {
        guard !missing else { throw .noInput }
        state.withLock { $0.counts.opens += 1 }
        let (samples, rate) = try DictationAudioFile.read(url)
        let block = Int(rate) / DictationAudioFile.blocksPerSecond
        for start in stride(from: 0, to: samples.count, by: block) {
            let end = min(start + block, samples.count)
            let through = from + .nanoseconds(Int64(end) * 1_000_000_000 / Int64(rate))
            ring.write(frames: end - start, capturedThrough: through) { samples[start + $0] }
        }
        return rate
    }

    func close() { state.withLock { $0.counts.closes += 1 } }
}
