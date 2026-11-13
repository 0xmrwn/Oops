import XCTest
@testable import OopsCore

/// Which mechanism receives the vocabulary for each engine family, and what it receives.
final class VocabularyRoutingTests: XCTestCase {
    let list = [VocabularyEntry(term: "Ghostty", soundsLike: ["ghosty"]), VocabularyEntry(term: "Tailscale")]

    func testParakeetTakesTheEnginesVocabularyExtension() throws {
        let delivery = try XCTUnwrap(VocabularyRouting.delivery(of: list, to: .local(.parakeet), boost: .strong))
        XCTAssertEqual(delivery, .parakeetBias(VocabularyBias(
            terms: ["Ghostty", "Tailscale"], soundsLike: [.init(termIndex: 0, spelling: "ghosty")], boost: 4
        )))
    }

    func testWhisperAndQwenTakeThePrompt() {
        for architecture in [SpeechModelArchitecture.whisper, .qwen3ASR] {
            XCTAssertEqual(VocabularyRouting.delivery(of: list, to: .local(architecture)), .prompt("Ghostty, Tailscale"))
        }
    }

    func testOpenAITakesKeywords() {
        XCTAssertEqual(VocabularyRouting.delivery(of: list, to: .openAI), .openAIKeywords(["Ghostty", "Tailscale"]))
    }

    func testAnEngineWithNoMechanismGetsFuzzyReplacement() {
        let others: [SpeechModelArchitecture] = [.senseVoice, .cohereASR, .gigaAM, .graniteSpeech5CTC, .sileroVAD]
        for architecture in others {
            XCTAssertEqual(
                VocabularyRouting.delivery(of: list, to: .local(architecture)), .fuzzyReplacement(["Ghostty", "Tailscale"]),
                "\(architecture)"
            )
        }
    }

    func testAnEmptyVocabularySendsNothingToAnyEngine() {
        let architectures: [SpeechModelArchitecture] = [
            .parakeet, .whisper, .qwen3ASR, .senseVoice, .cohereASR, .gigaAM, .graniteSpeech5CTC, .sileroVAD
        ]
        for engine in architectures.map(VocabularyEngine.local) + [.openAI] {
            XCTAssertNil(VocabularyRouting.delivery(of: [], to: engine), "\(engine)")
        }
    }

    func testTheRoutingFollowsTheCatalogsVocabularyUse() {
        for model in SpeechModelCatalog.models {
            let delivery = VocabularyRouting.delivery(of: list, to: .local(model.architecture))
            switch model.vocabularyUse {
            case .bias: guard case .parakeetBias = delivery else { return XCTFail(model.id) }
            case .prompt: guard case .prompt = delivery else { return XCTFail(model.id) }
            case .none: guard case .fuzzyReplacement = delivery else { return XCTFail(model.id) }
            }
        }
    }

    func testAListWithTheBoostOffSendsNoBias() {
        XCTAssertNil(VocabularyRouting.delivery(of: list, to: .local(.parakeet), boost: .off))
    }
}
