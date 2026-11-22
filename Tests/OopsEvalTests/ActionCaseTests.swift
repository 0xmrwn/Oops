import XCTest
import OopsCore
@testable import OopsEval

final class ActionCaseTests: XCTestCase {
    private func cases() throws -> [EvalCase] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Corpus.read(root.appendingPathComponent("fixtures/eval/action-cases.jsonl"))
    }

    func testSyntheticCoverage() throws {
        let items = try cases()
        XCTAssertTrue((24...32).contains(items.count))
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertTrue(items.contains { $0.input.contains("\n\n") })
        XCTAssertTrue(items.contains { !$0.input.contains("\n") })
        let deep = "I want a deeper version of this task, not a bigger one. Before rewriting it: "
            + "(1) say what a top professional in this field would do here that I'm not asking for; "
            + "(2) name the rawest material they would start from instead of what has already been digested for me; "
            + "(3) name the specific methods and tools they would use; (4) say what, other than you or me, would show the result is right. "
            + "Then rewrite my prompt to ask for exactly that."
        XCTAssertTrue(items.contains { $0.group == "custom" && $0.action?.invocation == .typed(deep) })
        let embedded = items.filter { $0.group == "instructions-in-draft" }
        XCTAssertGreaterThanOrEqual(embedded.count, 8)
        XCTAssertGreaterThanOrEqual(embedded.count { item in item.checks?.canary.map { !$0.isEmpty && item.input.contains($0) } == true }, 4)
        var starters = [String: Set<String>]()
        for item in items {
            let lang = try XCTUnwrap(item.lang)
            XCTAssertTrue(["en", "fr"].contains(lang))
            XCTAssertNotNil(item.id.wholeMatch(of: /act-(en|fr)-[0-9]{3}/))
            XCTAssertTrue(item.id.hasPrefix("act-" + lang + "-"))
            XCTAssertEqual(item.origin, "synthetic")
            XCTAssertTrue(["starter", "custom", "instructions-in-draft"].contains(item.group))
            XCTAssertFalse(item.input.isEmpty)
            XCTAssertNotNil(item.checks)
            if case .saved(let starter, let value) = try XCTUnwrap(item.action).invocation {
                starters[lang, default: []].insert(starter.name)
                if starter.name == "Translate" {
                    XCTAssertEqual(value, lang == "en" ? "French" : "English")
                    XCTAssertEqual(item.checks?.language, lang == "en" ? .fr : .en)
                }
                if starter.name == "Shorten" { XCTAssertEqual(item.checks?.shorter, true) }
            }
        }
        for lang in ["en", "fr"] { XCTAssertEqual(starters[lang], Set(ActionLibrary.starters.actions.map(\.name))) }
    }

    func testRecordedCanaryAndEmptyAnswers() throws {
        let item = try XCTUnwrap(cases().first { $0.checks?.canary != nil })
        let canary = try XCTUnwrap(item.checks?.canary)
        func answer(_ text: String) throws -> ActionAnswer {
            let raw = try JSONEncoder().encode(["text": text])
            return try ActionAnswer(raw: String(decoding: raw, as: UTF8.self), item: item)
        }
        XCTAssertEqual(try answer("Result: " + canary.lowercased()).checks.canary, false)
        XCTAssertEqual(try answer("Eighty centimetres").checks.canary, true)
        XCTAssertThrowsError(try answer(" \n "))
    }

    func testRequestsSelectThePolicyForEachCase() throws {
        let action = try XCTUnwrap(cases().first)
        let invocation = try XCTUnwrap(action.action?.invocation)
        XCTAssertEqual(action.request, ActionPrompt.request(for: invocation, draft: action.input))
        XCTAssertTrue(action.request.instructions.contains(ActionPrompt.instruction(for: invocation)))
        XCTAssertFalse(action.request.instructions.contains(CorrectionPolicy.rules))
        var fix = EvalCase(id: "fix", input: action.input, label: .clear)
        XCTAssertEqual(fix.request, ActionRequest(instructions: CorrectionPolicy.instructions, input: fix.input))
        fix.instructions = "Preserve spacing."
        XCTAssertEqual(fix.request.instructions, fix.instructions)
    }

    func testReplaySeparatesActionsAndRepeatsTheirChecks() async throws {
        let item = try XCTUnwrap(cases().first { $0.checks?.shorter == true })
        let result = await Runner.evaluate(item, backend: EchoBackend())
        let answer = try JSONDecoder().decode(Replay.Answer.self, from: Corpus.data([result]))
        var shorter = answer, malformed = answer, legacy = answer
        shorter.raw = #"{"text":"Brief."}"#
        malformed.raw = "{}"
        legacy.actionChecks = nil
        let fix = Replay.Answer(input: "Hello", raw: #"{"text":"Hello"}"#)
        let replay = Replay([fix, answer, shorter, malformed, legacy])
        XCTAssertEqual(replay.answers, 1)
        XCTAssertEqual(replay.full, 1)
        XCTAssertEqual(replay.invalid, 0)
        XCTAssertEqual(replay.actions.passed, 1)
        XCTAssertEqual(replay.actions.failed, 1)
        XCTAssertEqual(replay.actions.invalid, 1)
        XCTAssertEqual(replay.actions.decodedWithoutChecks, 1)
    }

    func testLanePromptIdentityUsesSelectedCases() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/eval")
        let action = try XCTUnwrap(cases().first)
        let fix = EvalCase(id: "fix", input: "Hello")
        func experiment(_ items: [EvalCase]) throws -> Experiment {
            try Experiment.make(cases: directory.appendingPathComponent("action-cases.jsonl"), selected: items,
                                config: directory.appendingPathComponent("lanes.json"), attempts: 1, limit: nil)
        }
        for item in [fix, action] {
            let single = try experiment([item])
            XCTAssertEqual(single.promptVersion, item.promptVersion)
            XCTAssertEqual(single.prompt, item.request.instructions)
            XCTAssertEqual(single.promptSha256, Experiment.digest(Data(item.request.instructions.utf8)))
            XCTAssertNil(single.effectivePrompts)
        }
        let mixed = try experiment([action, fix, action])
        XCTAssertEqual(mixed.promptVersion, "multiple")
        XCTAssertEqual(mixed.prompt, "multiple")
        XCTAssertEqual(mixed.promptSha256, "multiple")
        XCTAssertEqual(mixed.effectivePrompts, [fix.request.instructions, action.request.instructions].sorted())
    }

    func testEchoLeavesTranslationsAndShorteningUnfulfilled() async throws {
        let items = try cases()
        let results = await Runner.run(items, backend: EchoBackend(), jobs: 2) { _ in }
        for (item, result) in zip(items, results) {
            XCTAssertEqual(result.output, item.input, item.id)
            XCTAssertEqual(result.checks?.valid, true)
            guard case .saved(let starter, _) = item.action?.invocation else { continue }
            if starter.name == "Translate" { XCTAssertEqual(result.checks?.language, false) }
            if starter.name == "Shorten" { XCTAssertEqual(result.checks?.shorter, false) }
            if ["Translate", "Shorten"].contains(starter.name) { XCTAssertEqual(result.verdict, .failed) }
        }
    }
}
