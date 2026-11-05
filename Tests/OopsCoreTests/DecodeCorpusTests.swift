import XCTest
@testable import OopsCore

/// fixtures/corpus/decode.json: model answers and what decoding must make of them. Each case has
/// `answer` (wrapped as the schema object) or `raw`, and `expect` or `error`, with how many changes
/// were `dropped` as unsafe and `absorbed` as drift (zero when absent); `validate` cases check a full
/// corrected text against the original with the strict, all-or-nothing validator instead.
final class DecodeCorpusTests: XCTestCase {
    private struct Case: Decodable {
        let name: String
        let original: String
        let answer: String?
        let raw: String?
        let validate: String?
        let expect: String?
        let error: Bool?
        let dropped: Int?
        let absorbed: Int?
    }

    func testCorpus() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/corpus/decode.json")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let result: Result<String, Error>
            if let text = item.validate {
                result = Result { try CorrectionPolicy.validate(text, original: item.original); return text }
            } else {
                let raw = try item.raw ?? String(decoding: JSONSerialization.data(withJSONObject: ["text": XCTUnwrap(item.answer, item.name)]), as: UTF8.self)
                result = Result {
                    let reconciled = try CorrectionPolicy.reconcile(raw, original: item.original)
                    XCTAssertEqual(reconciled.dropped.count, item.dropped ?? 0, "\(item.name): dropped \(reconciled.dropped)")
                    XCTAssertEqual(reconciled.absorbed, item.absorbed ?? 0, "\(item.name): absorbed")
                    return reconciled.text
                }
            }
            switch (result, item.error == true) {
            case (.success(let text), false): if let expect = item.expect { XCTAssertTrue(sameText(text, expect), "\(item.name): \(text.debugDescription)") }
            case (.success(let text), true): XCTFail("\(item.name): accepted \(text.debugDescription)")
            case (.failure(let error), false): XCTFail("\(item.name): \(error.localizedDescription)")
            case (.failure, true): break
            }
        }
    }

    func testOversizedAnswerIsRefused() throws {
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["text": "ok" + String(repeating: " ", count: 32_000)]), as: UTF8.self)
        XCTAssertThrowsError(try CorrectionPolicy.decode(raw, original: "\tcorrect text \n"))
    }

    func testCustomRulesKeepTheContract() {
        defer { UserDefaults.standard.removeObject(forKey: CorrectionPolicy.customRulesKey) }
        UserDefaults.standard.set("  Fix typos only.\n", forKey: CorrectionPolicy.customRulesKey)
        XCTAssertEqual(CorrectionPolicy.instructions, "Fix typos only. " + CorrectionPolicy.contract)
        UserDefaults.standard.set("   ", forKey: CorrectionPolicy.customRulesKey)
        XCTAssertEqual(CorrectionPolicy.rules, CorrectionPolicy.defaultRules)
    }
}
