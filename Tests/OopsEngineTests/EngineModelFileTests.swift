import AVFoundation
import OopsCore
import OopsEngine
import XCTest

/// transcribe.cpp itself, through the engine: bad model files fail cleanly and the process carries on. The
/// recording needs a real model, from OOPS_TEST_MODEL.
final class EngineModelFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testAMissingModelIsNoModelFile() async {
        let engine = TranscribeEngine()
        await assertLoad(engine, directory.appendingPathComponent("absent.gguf"), fails: .noModelFile)
        // Nothing is remembered from the failed load.
        await assertTranscribe(engine, fails: .notLoaded)
    }

    func testTruncatedAndForeignFilesAreUnusableAndTheEngineCarriesOn() async throws {
        let engine = TranscribeEngine()
        // A GGUF header (magic, version 3) that promises tensors and metadata and stops there.
        let truncated = directory.appendingPathComponent("truncated.gguf")
        try (Data("GGUF".utf8) + Data([3, 0, 0, 0, 200, 0, 0, 0, 0, 0, 0, 0, 40, 0, 0, 0])).write(to: truncated)
        let empty = directory.appendingPathComponent("empty.gguf")
        try Data().write(to: empty)
        let foreign = directory.appendingPathComponent("foreign.gguf")
        try Data(repeating: 0x5A, count: 4096).write(to: foreign)
        var files = [truncated, empty, foreign]
        if let model = Self.model {
            // The real model, cut off a megabyte in.
            let cut = directory.appendingPathComponent("cut.gguf")
            let handle = try FileHandle(forReadingFrom: model)
            try handle.read(upToCount: 1 << 20)?.write(to: cut)
            try handle.close()
            files.append(cut)
        }
        for file in files {
            await assertLoad(engine, file, unusable: true)
        }
        await assertTranscribe(engine, fails: .notLoaded)
    }

    func testTheRecordingTranscribesToItsSentence() async throws {
        guard let model = Self.model else { throw XCTSkip("set OOPS_TEST_MODEL to a model file to run this") }
        let engine = TranscribeEngine()
        try await engine.warmUp(model: model)
        let samples = try Self.samples(Self.fixtures.appendingPathComponent("sentence.wav"))
        let text = try await engine.transcribe(samples)
        XCTAssertEqual(Self.words(text), "the quick brown fox jumps over the lazy dog", text)
        // A second use, and one after the model was let go, say the same.
        await engine.unload()
        try await engine.load(model: model)
        let again = try await engine.transcribe(samples)
        XCTAssertEqual(Self.words(again), Self.words(text))
        await engine.unload()
    }

    private func assertLoad(_ engine: TranscribeEngine, _ file: URL, fails expected: SpeechEngineError? = nil, unusable: Bool = false,
                            line: UInt = #line) async {
        do {
            try await engine.load(model: file)
            XCTFail("loaded \(file.lastPathComponent)", line: line)
        } catch {
            if unusable {
                guard case .unusableModel = error else { return XCTFail("\(file.lastPathComponent): \(error)", line: line) }
            } else {
                XCTAssertEqual(error, expected, line: line)
            }
        }
    }

    private func assertTranscribe(_ engine: TranscribeEngine, fails expected: SpeechEngineError, line: UInt = #line) async {
        do {
            _ = try await engine.transcribe([0])
            XCTFail("transcribed without a model", line: line)
        } catch {
            XCTAssertEqual(error, expected, line: line)
        }
    }

    private static var model: URL? {
        guard let path = ProcessInfo.processInfo.environment["OOPS_TEST_MODEL"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// Lowercase words only: punctuation and capitals are the model's style, not its hearing.
    private static func words(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    /// The fixture is 16 kHz mono already (`say -o … --data-format=LEI16@16000 --channels=1`).
    private static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
