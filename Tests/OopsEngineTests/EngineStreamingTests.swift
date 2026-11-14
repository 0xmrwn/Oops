import AVFoundation
@testable import OopsCore
@testable import OopsEngine
import Synchronization
import XCTest

/// Live words through the engine. With OOPS_TEST_MODEL set to a streaming model, the fixture sentence streams for real;
/// the rest runs on stand-in models, with an idle release that fires at once after each use.
final class EngineStreamingTests: XCTestCase {
    private let unified = URL(fileURLWithPath: "/models/parakeet-unified-en-0.6b-Q8_0.gguf")

    func testAStreamingModelYieldsWordsBeforeTheLastBlockAndWritesTheOneShotText() async throws {
        let path = try Self.testModel()
        guard SpeechModelCatalog.model(atPath: path)?.streams == true else {
            throw XCTSkip("set OOPS_TEST_MODEL to a streaming model")
        }
        let engine = TranscribeEngine()
        try await engine.warmUp(model: URL(fileURLWithPath: path))
        let samples = try Self.samples(Self.fixtures.appendingPathComponent("sentence.wav"))
        let oneShot = try await engine.transcribe(samples)
        let stream = try await engine.startStream(language: nil, vocabulary: nil)
        let updates = Updates()
        let collector = Task { for await words in stream.words { updates.add(words) } }
        let blocks = stride(from: 0, to: samples.count, by: 1280).map { Array(samples[$0 ..< min($0 + 1280, samples.count)]) }
        for block in blocks.dropLast() { await stream.append(block) }
        let deadline = ContinuousClock.now + .seconds(2)
        while updates.all.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(updates.all.isEmpty, "no live words before the last block")
        await stream.append(try XCTUnwrap(blocks.last))
        let written = try await stream.finish()
        await collector.value
        XCTAssertEqual(written, oneShot)
        XCTAssertFalse(try XCTUnwrap(updates.all.last).isEmpty)
    }

    func testANonStreamingModelRefusesAStream() async throws {
        if let path = ProcessInfo.processInfo.environment["OOPS_TEST_MODEL"], !path.isEmpty,
           SpeechModelCatalog.model(atPath: path)?.streams == false {
            let engine = TranscribeEngine()
            try await engine.load(model: URL(fileURLWithPath: path))
            await XCTAssertStreamRefused(engine, .streamingUnsupported)
        }
        let (engine, _) = make()
        try await engine.load(model: URL(fileURLWithPath: "/models/parakeet-tdt-0.6b-v3-Q8_0.gguf"))
        await XCTAssertStreamRefused(engine, .streamingUnsupported)
    }

    func testAFileTheCatalogDoesntPinCannotStream() async throws {
        let (engine, log) = make()
        try await engine.load(model: URL(fileURLWithPath: "/models/custom.gguf"))
        await XCTAssertStreamRefused(engine, .streamingUnsupported)
        XCTAssertEqual(log.begun, 0)
    }

    func testAStreamBeforeAnyLoadIsNotLoaded() async {
        let (engine, _) = make()
        await XCTAssertStreamRefused(engine, .notLoaded)
    }

    func testTheModelStaysLoadedWhileAStreamIsOpen() async throws {
        let (engine, log) = make()
        try await engine.load(model: unified)
        // Through the protocol, so the engine's own `startStream` answers, not the default that refuses.
        let speech: any SpeechEngine = engine
        let stream = try await speech.startStream(language: "en", vocabulary: nil)
        XCTAssertEqual(log.languages, ["en"])
        await engine.idleTask?.value
        var held = await engine.holdsModel
        XCTAssertTrue(held)
        await stream.append([Float](repeating: 0.1, count: 3000))
        await engine.idleTask?.value
        held = await engine.holdsModel
        XCTAssertTrue(held)
        await stream.cancel()
        await stream.cancel()
        await engine.idleTask?.value
        held = await engine.holdsModel
        XCTAssertFalse(held)
        // Each 80 ms of audio is fed on its own, so the words can change after each.
        XCTAssertEqual(log.fed, [1280, 1280, 440])
        var words: [String] = []
        for await live in stream.words { words.append(live.text) }
        XCTAssertEqual(words, ["1280", "2560", "3000"])
    }

    func testAOneShotRunEndsAnOpenStream() async throws {
        let (engine, log) = make()
        try await engine.load(model: unified)
        let stream = try await engine.startStream(language: nil, vocabulary: nil)
        _ = try await engine.transcribe([0.1])
        XCTAssertEqual(log.resets, 1)
        await stream.append([0.1, 0.2])
        XCTAssertEqual(log.fed, [])
    }

    func testAnEarlierStreamStillFinishesAfterANewOneStarts() async throws {
        let (engine, log) = make()
        try await engine.load(model: unified)
        let first = try await engine.startStream(language: nil, vocabulary: nil)
        await first.append([0.1, 0.2, 0.3])
        let second = try await engine.startStream(language: nil, vocabulary: nil)
        await first.append([0.4])
        await second.append([0.5, 0.6])
        // The first's late audio isn't fed into the second's stream, but its own text still has it.
        XCTAssertEqual(log.fed, [3, 2])
        let firstText = try await first.finish()
        let secondText = try await second.finish()
        XCTAssertEqual(firstText, "4 samples")
        XCTAssertEqual(secondText, "2 samples")
        await first.append([0.7])
        XCTAssertEqual(log.runs, [4, 2])
        let afterFinish = try await first.finish()
        XCTAssertEqual(afterFinish, "")
    }

    private func make() -> (TranscribeEngine, StreamLog) {
        let log = StreamLog()
        let release = TranscribeEngine.IdleRelease(after: .zero) { _ in }
        let engine = TranscribeEngine(idleRelease: release) { _ throws(SpeechEngineError) in Streamer(log: log) }
        return (engine, log)
    }

    private func XCTAssertStreamRefused(_ engine: TranscribeEngine, _ expected: SpeechEngineError,
                                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await engine.startStream(language: nil, vocabulary: nil)
            XCTFail("streamed", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private static func testModel() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["OOPS_TEST_MODEL"], !path.isEmpty else {
            throw XCTSkip("set OOPS_TEST_MODEL to a streaming model")
        }
        return path
    }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// The fixture is 16 kHz mono already.
    private static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}

/// Live words as a stream publishes them.
private final class Updates: Sendable {
    private let state = Mutex([LiveWords]())
    var all: [LiveWords] { state.withLock { $0 } }
    func add(_ words: LiveWords) { state.withLock { $0.append(words) } }
}

/// What the stand-in models saw: streams begun (and their language), feeds, resets and one-shot runs.
private final class StreamLog: Sendable {
    private let state = Mutex((languages: [String?](), fed: [Int](), resets: 0, runs: [Int]()))
    var begun: Int { state.withLock { $0.languages.count } }
    var languages: [String?] { state.withLock { $0.languages } }
    var fed: [Int] { state.withLock { $0.fed } }
    var resets: Int { state.withLock { $0.resets } }
    var runs: [Int] { state.withLock { $0.runs } }
    func begin(_ language: String?) { state.withLock { $0.languages.append(language) } }
    func feed(_ count: Int) { state.withLock { $0.fed.append(count) } }
    func reset() { state.withLock { $0.resets += 1 } }
    func run(_ count: Int) { state.withLock { $0.runs.append(count) } }
}

/// A model that streams anything: its words are the number of samples fed since the stream began.
private final class Streamer: LoadedModel {
    private let log: StreamLog
    private var fed = 0

    init(log: StreamLog) { self.log = log }

    func run(_ samples: [Float], language: String?, vocabulary: VocabularyDelivery?) throws(SpeechEngineError) -> String {
        log.run(samples.count)
        return "\(samples.count) samples"
    }

    func beginStream(_ context: SpeechModelLiveContext, language: String?) throws(SpeechEngineError) {
        log.begin(language)
        fed = 0
    }

    func feedStream(_ samples: [Float]) throws(SpeechEngineError) -> LiveWords? {
        log.feed(samples.count)
        fed += samples.count
        return LiveWords(stable: "\(fed)")
    }

    func resetStream() { log.reset() }
}
