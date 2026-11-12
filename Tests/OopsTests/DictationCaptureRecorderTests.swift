@testable import Oops
import OopsCore
import Synchronization
import XCTest

/// The recorder, the WAV source and the ring, with a WAV file in place of the microphone. Nothing here
/// opens the microphone or asks for access.
final class DictationCaptureRecorderTests: XCTestCase {
    private let origin = CaptureInstant(nanoseconds: 60_000_000_000)

    // From Hex's `src/audio/fixture.rs` (1b82cc0).
    func testAFixturePlaysItsFileFromTheStartInTenMsChunks() throws {
        let url = try wavFile(int16: (0 ..< 120).flatMap { [Int16($0 * 100), Int16($0 * 100)] }, channels: 2, rate: 8_000)
        let (samples, rate) = try DictationAudioFile.read(url)
        XCTAssertEqual(rate, 8_000)
        XCTAssertEqual(samples.count, 120)

        let file = DictationAudioFile(url: url)
        let ring = DictationAudioRing()
        _ = try file.open(into: ring)
        defer { file.close() }
        var heard: [Float] = []
        var last = CaptureInstant.zero
        let deadline = ContinuousClock.now + .seconds(2)
        while heard.count < 160 {
            XCTAssertLessThan(ContinuousClock.now, deadline, "the fixture stopped delivering")
            if ContinuousClock.now >= deadline { return }
            ring.drain { block, through in
                XCTAssertEqual(block.count, 80)
                XCTAssertGreaterThan(through, last)
                last = through
                heard += block
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        // It loops: the 121st sample is the first again.
        XCTAssertEqual(heard[0], heard[120])
        XCTAssertEqual(heard[1], 100 / 32_768, accuracy: 1e-6)
    }

    func testTheRingDropsWhatDoesNotFitAndKeepsOrder() {
        let ring = DictationAudioRing(sampleCapacity: 1_024, blockCapacity: 4)
        for block in 1 ... 3 {
            ring.write(frames: 400, capturedThrough: origin + .milliseconds(block * 10)) { _ in Float(block) }
        }
        XCTAssertEqual(ring.droppedFrames, 400)
        var blocks: [[Float]] = []
        ring.drain { block, _ in blocks.append(block) }
        XCTAssertEqual(blocks, [repeated(1, 400), repeated(2, 400)])
        XCTAssertTrue(ring.write(frames: 1_000, capturedThrough: origin) { _ in 0 }, "drained space is free again")
    }

    func testARecordingRunsFromThePressThroughTheReleaseTail() async throws {
        let audio = speech(rate: 16_000)
        let recorder = DictationRecorder(source: try immediateFile(audio, rate: 16_000), keepAliveSleep: Self.never)
        try await recorder.start(at: origin + .milliseconds(400))
        let outcome = await recorder.stop(at: origin + .milliseconds(1_600))
        // Speech ends 100 ms before the release, so the base tail is kept: 400 ms to 1.8 s, exactly.
        XCTAssertEqual(outcome, .samples(Array(audio[6_400 ..< 28_800])))
    }

    func testARecordingAtTheDeviceRateIsConvertedTo16kHz() async throws {
        let recorder = DictationRecorder(source: try immediateFile(speech(rate: 48_000), rate: 48_000), keepAliveSleep: Self.never)
        try await recorder.start(at: origin + .milliseconds(400))
        guard case let .samples(samples) = await recorder.stop(at: origin + .milliseconds(1_600)) else { return XCTFail("expected samples") }
        XCTAssertLessThanOrEqual(abs(samples.count - 22_400), 16, "\(samples.count)")
        XCTAssertLessThan(samples[..<1_280].map(abs).max() ?? 1, 0.01, "the 80 ms before the speech stay quiet")
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.25)
    }

    func testSilenceAndDigitalSilenceWriteNothing() async throws {
        let quiet = (0 ..< 48_000).map { Float(0.000_7) * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
        for (audio, discard) in [(quiet, DictationRecorder.Discard.silence), (repeated(0, 48_000), .digitalSilence)] {
            let recorder = DictationRecorder(source: try immediateFile(audio, rate: 16_000), keepAliveSleep: Self.never)
            try await recorder.start(at: origin + .milliseconds(400))
            let outcome = await recorder.stop(at: origin + .milliseconds(1_600))
            XCTAssertEqual(outcome, .discarded(discard))
        }
    }

    func testStartingWithoutMicrophoneAccessFailsWithoutAsking() async {
        for access in [DictationMicrophoneAccess.denied, .undetermined] {
            let recorder = DictationRecorder(source: DictationMicrophone(access: { access }), keepAliveSleep: Self.never)
            do {
                try await recorder.start()
                XCTFail("started without access")
            } catch {
                XCTAssertEqual(error, .microphoneAccess(access))
            }
            let open = await recorder.isSourceOpen
            XCTAssertFalse(open)
        }
    }

    func testTheSourceStaysOpenForTheKeepAliveThenCloses() async throws {
        XCTAssertEqual(DictationRecorder.keepAlive, .seconds(10))
        let source = CountingSource(DictationAudioFile(url: try wavFile(float: speech(rate: 16_000), rate: 16_000)))
        let sleeps = HeldSleeps()
        let recorder = DictationRecorder(source: source, keepAliveSleep: sleeps.sleep)

        try await recorder.start()
        try await Task.sleep(for: .milliseconds(100))
        _ = await recorder.stop()
        let afterFirst = await recorder.isSourceOpen
        XCTAssertTrue(afterFirst)
        try await sleeps.waitForSleepers(1)
        XCTAssertEqual(sleeps.durations, [DictationRecorder.keepAlive])

        // A second dictation inside the keep-alive reuses the open source, and the first close no longer applies.
        try await recorder.start()
        try await Task.sleep(for: .milliseconds(100))
        _ = await recorder.stop()
        try await sleeps.waitForSleepers(2)
        sleeps.release(0)
        try await Task.sleep(for: .milliseconds(100))
        let afterStaleClose = await recorder.isSourceOpen
        XCTAssertTrue(afterStaleClose)
        XCTAssertEqual(source.counts.opens, 1)

        sleeps.release(1)
        try await eventually { await !recorder.isSourceOpen }
        XCTAssertEqual(source.counts.opens, 1)
        XCTAssertEqual(source.counts.closes, 1)
    }

    func testCancelDropsTheRecordingAndKeepsTheSourceWarm() async throws {
        let sleeps = HeldSleeps()
        let recorder = DictationRecorder(source: DictationAudioFile(url: try wavFile(float: speech(rate: 16_000), rate: 16_000)), keepAliveSleep: sleeps.sleep)
        try await recorder.start()
        try await Task.sleep(for: .milliseconds(50))
        await recorder.cancel()
        let outcome = await recorder.stop()
        XCTAssertEqual(outcome, .discarded(.notRecording))
        let open = await recorder.isSourceOpen
        XCTAssertTrue(open)
        try await sleeps.waitForSleepers(1)
        sleeps.release(0)
        try await eventually { await !recorder.isSourceOpen }
    }

    func testAPressBeforeTheFirstAudioRecordsFromTheFirstBlock() async throws {
        let tone = (0 ..< 48_000).map { Float(0.1) * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
        let recorder = DictationRecorder(source: DictationAudioFile(url: try wavFile(float: tone, rate: 16_000)), keepAliveSleep: Self.never)
        let pressed = CaptureInstant.now()
        try await recorder.start(at: pressed)
        try await Task.sleep(for: .milliseconds(150))
        let released = CaptureInstant.now()
        let outcome = await recorder.stop(at: released)
        guard case let .samples(samples) = outcome else { return XCTFail("expected samples, got \(outcome)") }
        // The source opened on the press, so the clip runs from its first block, just after the press,
        // through the 200 ms tail.
        let held = samplesFor(released.duration(since: pressed) + DictationCapture.postReleaseTail)
        XCTAssertTrue((held - 480 ... held).contains(samples.count), "\(samples.count) of \(held)")
    }

    // MARK: - Support

    private func samplesFor(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 16_000 + Int(duration.components.attoseconds / 62_500_000_000_000)
    }

    private static let never: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3_600)) }

    /// A file with 0.5 s of silence, 1 s of a 180 Hz voice at -13 dBFS, then 1.5 s of silence.
    private func speech(rate: Int) -> [Float] {
        (0 ..< rate * 3).map { index in
            let seconds = Double(index) / Double(rate)
            return (0.5 ..< 1.5).contains(seconds) ? 0.3 * Float(sin(2 * Double.pi * 180 * seconds)) : 0
        }
    }

    private func immediateFile(_ samples: [Float], rate: Int) throws -> DictationAudioFile {
        DictationAudioFile(url: try wavFile(float: samples, rate: rate), pace: .immediate(from: origin))
    }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Keep-alive sleeps the test ends by hand.
final class HeldSleeps: Sendable {
    private let state = Mutex<(durations: [Duration], waiting: [CheckedContinuation<Void, Never>?])>(([], []))

    var durations: [Duration] { state.withLock { $0.durations } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { duration in
            await withCheckedContinuation { continuation in
                self.state.withLock { $0.durations.append(duration); $0.waiting.append(continuation) }
            }
        }
    }

    func release(_ index: Int) {
        state.withLock { state in defer { state.waiting[index] = nil }; return state.waiting[index] }?.resume()
    }

    func waitForSleepers(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while state.withLock({ $0.waiting.count }) < count {
            guard ContinuousClock.now < deadline else { return XCTFail("no keep-alive sleep started") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Counts how often a source opens and closes.
final class CountingSource: DictationAudioSource {
    private let inner: any DictationAudioSource
    private let state = Mutex((opens: 0, closes: 0))

    init(_ inner: any DictationAudioSource) { self.inner = inner }

    var counts: (opens: Int, closes: Int) { state.withLock { $0 } }

    func open(into ring: DictationAudioRing) throws(DictationAudioError) -> Double {
        state.withLock { $0.opens += 1 }
        return try inner.open(into: ring)
    }

    func close() {
        state.withLock { $0.closes += 1 }
        inner.close()
    }
}

extension XCTestCase {
    /// A mono Float32 WAV of `float` at `rate`, removed after the test.
    func wavFile(float samples: [Float], rate: Int) throws -> URL {
        try wavFile(format: 3, bits: 32, channels: 1, rate: rate, payload: samples.withUnsafeBytes { Data($0) })
    }

    /// A 16-bit WAV of interleaved `int16` samples, removed after the test.
    func wavFile(int16 samples: [Int16], channels: Int, rate: Int) throws -> URL {
        try wavFile(format: 1, bits: 16, channels: channels, rate: rate, payload: samples.withUnsafeBytes { Data($0) })
    }

    private func wavFile(format: UInt16, bits: UInt16, channels: Int, rate: Int, payload: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dictation-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var data = Data()
        func append(_ value: some FixedWidthInteger) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let frameBytes = channels * Int(bits) / 8
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + payload.count)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(format); append(UInt16(channels)); append(UInt32(rate)); append(UInt32(rate * frameBytes))
        append(UInt16(frameBytes)); append(bits)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(payload.count)); data.append(payload)
        let url = directory.appending(path: "audio.wav")
        try data.write(to: url)
        return url
    }
}
