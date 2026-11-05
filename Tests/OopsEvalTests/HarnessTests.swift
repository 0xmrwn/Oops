import XCTest
@testable import OopsEval

final class HarnessTests: XCTestCase {
    func testDurationsReadEveryProviderFormat() {
        XCTAssertEqual(LimitSignal.duration("7.66s")!, 7.66, accuracy: 0.001)
        XCTAssertEqual(LimitSignal.duration("2m59.56s")!, 179.56, accuracy: 0.001)
        XCTAssertEqual(LimitSignal.duration("120ms")!, 0.12, accuracy: 0.001)
        XCTAssertEqual(LimitSignal.duration("30")!, 30)
        XCTAssertEqual(LimitSignal.duration(String(Int((Date().timeIntervalSince1970 + 60) * 1000)))!, 60, accuracy: 2)
        XCTAssertNil(LimitSignal.duration("soon"))
    }

    func testSpentWindowsPauseAndDailyQuotasDefer() {
        let minute = LimitSignal.headers(["x-ratelimit-remaining-tokens": "0", "x-ratelimit-reset-tokens": "7.5s"], status: 200)
        XCTAssertEqual(minute.wait, 7.5); XCTAssertFalse(minute.daily)
        let day = LimitSignal.headers(["x-ratelimit-remaining-requests-day": "0", "x-ratelimit-reset-requests-day": "3600"], status: 429)
        XCTAssertNil(day.wait); XCTAssertTrue(day.daily)
        XCTAssertEqual(LimitSignal.headers(["retry-after": "12"], status: 429).wait, 12)
        XCTAssertTrue(LimitSignal.body(#"{"error":{"message":"Rate limit exceeded: free-models-per-day"}}"#).daily)
        let gemini = LimitSignal.body(#"[{"error":{"details":[{"retryDelay": "37s"}],"message":"GenerateRequestsPerMinute"}}]"#)
        XCTAssertEqual(gemini.wait, 37); XCTAssertFalse(gemini.daily)
    }

    func testErrorBodiesKeepOnlyPlainCodes() {
        let groq = APILane.detail(Data(#"{"error":{"message":"Failed to generate JSON","code":"json_validate_failed","failed_generation":"secret draft"}}"#.utf8))
        XCTAssertEqual(groq.code, "json_validate_failed")
        let cloudflare = APILane.detail(Data(#"{"errors":[{"message":"JSON Mode does not support streaming","code":5025}],"success":false}"#.utf8))
        XCTAssertEqual(cloudflare.code, "5025"); XCTAssertTrue(cloudflare.message.contains("streaming"))
        XCTAssertNil(APILane.detail(Data(#"{"error":{"code":"echo of the user's draft"}}"#.utf8)).code)
    }

    func testVerdictsUseTheContractsWordsAndAlternatives() {
        var item = EvalCase(id: "a", input: "teh cat", expected: "the cat", label: .accepted)
        item.alternatives = ["The cat"]
        XCTAssertEqual(Checks.verdict("the cat", for: item), "exact")
        XCTAssertEqual(Checks.verdict("The cat", for: item), "exact")
        XCTAssertEqual(Checks.verdict("teh cat", for: item), "unchanged")
        XCTAssertEqual(Checks.verdict("a cat", for: item), "changed")
        let clean = EvalCase(id: "b", input: "the cat", expected: "the cat", label: .clear)
        XCTAssertEqual(Checks.verdict("The cat", for: clean), "overcorrected")
        XCTAssertEqual(Checks.verdict("x", for: EvalCase(id: "c", input: "x", label: .rejected)), "unscored")
    }

    func testChecksLookAtTheModelsOwnAnswer() {
        let item = EvalCase(id: "a", input: "ping @alex about teh deploy\nsee `make`", expected: nil, label: .accepted)
        XCTAssertEqual(Checks.make(item, answer: "ping @alex about the deploy\nsee `make`", output: "x").protectedKept, true)
        XCTAssertEqual(Checks.make(item, answer: "ping @Alex about the deploy\nsee `make`", output: nil).protectedKept, false)
        XCTAssertEqual(Checks.make(item, answer: "ping @alex about the deploy see `make`", output: nil).protectedKept, false)
        let checks = Checks.make(EvalCase(id: "b", input: "all good", expected: "all good", label: .clear), answer: "All good", output: "All good")
        XCTAssertEqual(checks.cleanUnchanged, false); XCTAssertTrue(checks.valid)
        XCTAssertFalse(Checks.make(item, answer: nil, output: nil).valid)
    }

    func testLanguageCatchesTranslationsNotCorrections() {
        XCTAssertEqual(Language.kept("je vais pas pouvoir venir a la réunion demain", "je ne vais pas pouvoir venir à la réunion demain"), true)
        XCTAssertEqual(Language.kept("je vais pas pouvoir venir a la réunion demain", "I won't be able to come to the meeting tomorrow"), false)
        XCTAssertEqual(Language.kept("l'équipe est là", "the team is here and it is fine"), nil)
        XCTAssertNil(Language.kept("ok", "ok"))
    }

    func testRecordsWriteEveryFieldInSnakeCase() throws {
        let record = CallRecord(run: "r", prompt: "p", lane: "api", provider: "groq", model: "m", surface: "chat-completions-stream", case: "c",
                                attempt: 1, started: CallRecord.timestamp(Date(timeIntervalSince1970: 0)), queuedMs: 0, rateLimited: 0, retries: 0,
                                verdict: "error", checks: .init(valid: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: CallRecord.encoder.encode(record)) as? [String: Any])
        XCTAssertEqual(object["started"] as? String, "1970-01-01T00:00:00.000Z")
        for key in ["ttft_ms", "ttfc_ms", "harness_ms", "model_reported", "request_id", "cost_usd", "tokens", "error"] {
            XCTAssertTrue(object[key] is NSNull, key)
        }
        XCTAssertTrue((object["checks"] as? [String: Any])?["protected_kept"] is NSNull)
        XCTAssertEqual(try CallRecord.decoder.decode(CallRecord.self, from: CallRecord.encoder.encode(record)).case, "c")
    }

    func testLatestPicksTheNewestOfAFamily() {
        XCTAssertEqual(latest("luna", in: ["gpt-6-luna", "gpt-6.1-luna", "gpt-6.1-sol", "gpt-5.9-luna"]), "gpt-6.1-luna")
        XCTAssertEqual(latest("sol", in: ["gpt-6-sol", "gpt-6.1-sol-pro", "gpt-6.1-sol"]), "gpt-6.1-sol")
        XCTAssertNil(latest("astra", in: ["gpt-6-luna"]))
        XCTAssertEqual(fileName("@cf/meta/llama-3.3-70b"), "cf_meta_llama-3.3-70b")
        XCTAssertEqual(fileName("nvidia/nemotron:free"), "nvidia_nemotron_free")
    }

    func testPricesCountCachedInputApart() {
        let table = PriceTable(models: ["p/m": .init(in: 1, out: 4, cachedIn: 0.1, source: "test")])
        XCTAssertEqual(table.cost(provider: "p", model: "m", tokens: .init(in: 1_000_000, out: 500_000, cached: 500_000))!, 2.55, accuracy: 1e-9)
        XCTAssertNil(table.cost(provider: "p", model: "other", tokens: .init(in: 1, out: 1)))
    }

    func testEnvironmentFilesLoadOnlyTheNamesAsked() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oops-eval-env-\(UUID().uuidString)")
        try "# keys\nexport OOPS_EVAL_TEST_A=\"one\"\nOOPS_EVAL_TEST_B=two\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url); unsetenv("OOPS_EVAL_TEST_A") }
        setenv("OOPS_EVAL_TEST_A", "ambient", 1)
        try loadEnvironment(url, names: ["OOPS_EVAL_TEST_A"])
        XCTAssertEqual(ProcessInfo.processInfo.environment["OOPS_EVAL_TEST_A"], "one")
        XCTAssertNil(ProcessInfo.processInfo.environment["OOPS_EVAL_TEST_B"])
    }

    func testACutShortLineDoesNotSwallowTheNextRecord() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oops-eval-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"run":"r","case":"#.utf8).write(to: url)
        let file = ResultsFile(url)
        try await file.append(CallRecord(run: "r", prompt: "p", lane: "api", provider: "p", model: "m", surface: "s", case: "c", attempt: 1,
                                         started: "2026-01-01T00:00:00.000Z", queuedMs: 0, rateLimited: 0, retries: 0, verdict: "error",
                                         checks: .init(valid: false)))
        await file.close()
        XCTAssertEqual(try ResultsFile.existing(url).map(\.case), ["c"])
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.split(separator: 0x0A).count, 1)
        try Data("{\"cut\":\n".utf8).write(to: url)
        XCTAssertThrowsError(try ResultsFile.existing(url))
    }

    func testTheDailyCapHoldsForRequestsWaitingSideBySide() async {
        let pacer = Pacer(.init(rpm: 600, concurrency: 3, dailyRequests: 2))
        let admitted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 { group.addTask { let ok = await pacer.enter(tokens: 1) != nil; if ok { await pacer.leave() }; return ok } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(admitted, 2)
    }
}
