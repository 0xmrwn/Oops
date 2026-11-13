import XCTest
@testable import OopsCore

/// Hex's tests of what the vocabulary hands each engine (`src/dictation/vocabulary.rs` at 1b82cc0), each under its
/// upstream name in the Swift style.
final class VocabularyBiasTests: XCTestCase {
    func entry(_ term: String, _ soundsLike: [String] = []) -> VocabularyEntry {
        VocabularyEntry(term: term, soundsLike: soundsLike)
    }

    func testTranscriptionBiasKeepsTheFirstTermsAndTheirSpellings() throws {
        XCTAssertNil(VocabularyBias.make([], boost: .normal))
        var list = [entry("Cappuccino", ["capuchin", "cap a chino"]), entry("Rune")]
        list += (0 ..< 70).map { entry("term \($0)", ["x"]) }
        let bias = try XCTUnwrap(VocabularyBias.make(list, boost: .strong))
        XCTAssertEqual(bias.terms.count, VocabularyBias.maxTerms)
        XCTAssertEqual(Array(bias.terms[..<2]), ["Cappuccino", "Rune"])
        XCTAssertEqual(bias.boost, 4)
        XCTAssertEqual(Array(bias.soundsLike[..<2]), [
            .init(termIndex: 0, spelling: "capuchin"), .init(termIndex: 0, spelling: "cap a chino")
        ])
        XCTAssertEqual(bias.soundsLike[2], .init(termIndex: 2, spelling: "x"))
        XCTAssertTrue(bias.soundsLike.allSatisfy { $0.termIndex < VocabularyBias.maxTerms })
    }

    func testAnOffBoostBiasesNothing() {
        XCTAssertNil(VocabularyBias.make([entry("Rune")], boost: .off))
    }

    func testThePromptKeepsTheFirstTermsThatFit() throws {
        let list = [entry("Kaffar", ["Caffer"]), entry("Rodolfo"), entry("Bragelonne")]
        XCTAssertEqual(VocabularyPrompt.make(list, maxCharacters: 100), "Kaffar, Rodolfo, Bragelonne")
        XCTAssertEqual(VocabularyPrompt.make(list, maxCharacters: 20), "Kaffar, Rodolfo")
        XCTAssertNil(VocabularyPrompt.make(list, maxCharacters: 3))
        XCTAssertNil(VocabularyPrompt.make([], maxCharacters: 100))
        let many = (0 ..< 100).map { entry("T\($0)") }
        // Only the character budget limits the prompt, not the bias's term cap.
        XCTAssertEqual(try XCTUnwrap(VocabularyPrompt.make(many, maxCharacters: 10_000)).components(separatedBy: ", ").count, 100)
        let prompt = try XCTUnwrap(VocabularyPrompt.make(many, maxCharacters: 1_000))
        XCTAssertGreaterThan(prompt.components(separatedBy: ", ").count, VocabularyBias.maxTerms)
        XCTAssertLessThanOrEqual(prompt.count, 1_000)
    }

    func testTermsReadCountsExactlyWhatTranscriptionTakes() throws {
        let many = (0 ..< 200).map { entry("Term number \($0)") }
        for count in [0, 1, 20, 40, 64, 65, 200] {
            let list = Array(many[..<count])
            for architecture in [SpeechModelArchitecture.whisper, .qwen3ASR] {
                let limit = try XCTUnwrap(VocabularyPrompt.maxCharacters(for: architecture))
                let taken = VocabularyPrompt.make(list, maxCharacters: limit).map { $0.components(separatedBy: ", ").count } ?? 0
                XCTAssertEqual(VocabularyPrompt.termsRead(list, architecture: architecture), taken, "\(architecture) \(count)")
            }
            XCTAssertEqual(
                VocabularyPrompt.termsRead(list, architecture: .parakeet), VocabularyBias.make(list)?.terms.count ?? 0
            )
            XCTAssertEqual(VocabularyPrompt.termsRead(list, architecture: .senseVoice), 0)
        }
        XCTAssertEqual(VocabularyPrompt.termsRead(many, architecture: .parakeet), VocabularyBias.maxTerms)
        XCTAssertLessThan(
            VocabularyPrompt.termsRead(many, architecture: .whisper), VocabularyPrompt.termsRead(many, architecture: .qwen3ASR)
        )
        XCTAssertLessThan(VocabularyPrompt.termsRead(many, architecture: .qwen3ASR), many.count)
    }

    func testBoostReadsAndWritesAsItsName() throws {
        for boost in VocabularyBoost.allCases {
            XCTAssertEqual(try JSONDecoder().decode([VocabularyBoost].self, from: JSONEncoder().encode([boost])), [boost])
        }
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([VocabularyBoost.strong]), as: UTF8.self), #"["strong"]"#)
        XCTAssertEqual(VocabularyBoost.normal.nats, 2.5)
    }
}
