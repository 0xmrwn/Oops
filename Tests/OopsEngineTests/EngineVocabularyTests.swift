import AVFoundation
@testable import OopsCore
@testable import OopsEngine
import XCTest

/// The vocabulary reaching transcribe.cpp. With OOPS_TEST_MODEL set to a Parakeet model, the fixture sentence takes a
/// term's spelling only with the list; without it, the recording runs on no model and only the binding's plain rules run.
final class EngineVocabularyTests: XCTestCase {
    /// "fox" declared as a mishearing of "Fawkes": Parakeet replaces a declared spelling without acoustic scoring.
    private static let fawkes = [VocabularyEntry(term: "Fawkes", soundsLike: ["fox"])]

    func testAParakeetModelWritesTheTermWithTheListAndTheHeardWordWithout() async throws {
        guard let path = ProcessInfo.processInfo.environment["OOPS_TEST_MODEL"], !path.isEmpty else {
            throw XCTSkip("set OOPS_TEST_MODEL to a Parakeet model file to run this")
        }
        let engine = TranscribeEngine()
        try await engine.warmUp(model: URL(fileURLWithPath: path))
        let samples = try Self.samples(Self.fixtures.appendingPathComponent("sentence.wav"))
        let bias = try XCTUnwrap(VocabularyRouting.delivery(of: Self.fawkes, to: .local(.parakeet)))
        let without = try await engine.transcribe(samples)
        let with = try await engine.transcribe(samples, vocabulary: bias)
        XCTAssertTrue(Self.words(without).contains("brown fox jumps"), without)
        XCTAssertTrue(Self.words(with).contains("brown fawkes jumps"), with)
        XCTAssertFalse(Self.words(with).contains(" fox "), with)
        // An empty list sends nothing: the same text as no list at all.
        let empty = try await engine.transcribe(samples, vocabulary: VocabularyRouting.delivery(of: [], to: .local(.parakeet)))
        XCTAssertEqual(empty, without)
    }

    func testOnlyAModelThatTakesAListGetsIt() throws {
        let bias = try XCTUnwrap(VocabularyBias.make(Self.fawkes))
        // No model to ask: nothing is sent, and a run with no language needs no params at all.
        for delivery: VocabularyDelivery? in [nil, .parakeetBias(bias), .prompt("Fawkes"), .fuzzyReplacement(["Fawkes"]), .openAIKeywords(["Fawkes"])] {
            let options = RunOptions(language: nil, vocabulary: delivery, model: nil)
            XCTAssertNil(options.bias)
            XCTAssertNil(options.prompt)
            XCTAssertFalse(options.isNeeded)
        }
        XCTAssertTrue(RunOptions(language: "en", vocabulary: nil, model: nil).isNeeded)
    }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private static func words(_ text: String) -> String {
        " " + text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
    }

    /// The fixture is 16 kHz mono already.
    private static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
