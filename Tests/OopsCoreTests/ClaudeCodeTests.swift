import XCTest
@testable import OopsCore

final class ClaudeCodeTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testCorrectionArgumentsKeepOopsPromptAndDisableTools() throws {
        let arguments = ClaudeCode.correctionArguments(model: "haiku", effort: "low")
        XCTAssertEqual(Array(arguments.prefix(2)), ["--safe-mode", "-p"])
        XCTAssertFalse(arguments.contains("--bare"), "bare mode skips subscription sign-in")
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        XCTAssertEqual(value("--tools"), "")
        XCTAssertEqual(value("--model"), "haiku")
        XCTAssertEqual(value("--effort"), "low")
        XCTAssertEqual(value("--system-prompt"), CorrectionPolicy.instructions)
        XCTAssertEqual(value("--output-format"), "stream-json")
        let schema = try object(XCTUnwrap(value("--json-schema")))
        XCTAssertEqual(schema["required"] as? [String], ["text"])
        XCTAssertNil(ClaudeCode.correctionArguments(model: "claude-haiku-4-5", effort: nil).firstIndex(of: "--effort"))
    }

    func testStatusReadsSignInWithoutTrustingOtherShapes() {
        let signedIn = ClaudeCode.decodeStatus(Data(#"{"loggedIn":true,"authMethod":"claude.ai","orgName":"Acme","email":"a@example.com"}"#.utf8))
        XCTAssertEqual(signedIn, .signedIn(.init(email: "a@example.com", organization: "Acme", plan: nil)))
        XCTAssertEqual(ClaudeCode.decodeStatus(Data(#"{"loggedIn":false}"#.utf8)), .signedOut)
        XCTAssertEqual(ClaudeCode.decodeStatus(Data("not json".utf8)), .signedOut)
    }

    func testCatalogDropsDefaultAliasAndKeepsEffortsAndAccount() throws {
        let event = try object(#"""
        {"type":"control_response","response":{"subtype":"success","request_id":"oops-catalog","response":{
          "models":[
            {"value":"default","resolvedModel":"claude-sonnet-5-5","displayName":"Default (recommended)","supportedEffortLevels":["low"]},
            {"value":"haiku","resolvedModel":"claude-haiku-5-5","displayName":"Haiku 5.5","description":"Fastest for quick answers","supportedEffortLevels":["low","medium","high","xhigh","max"]},
            {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","supportedEffortLevels":["low","max"],"supportsFastMode":true},
            {"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","supportsThinkingOff":true}],
          "account":{"email":"a@example.com","organization":"Acme","subscriptionType":"Claude Team"}}}}
        """#)
        let (models, account) = try ClaudeCode.decodeCatalog(event)
        XCTAssertEqual(models.map(\.value), ["haiku", "opus", "claude-haiku-4-5-20251001"])
        XCTAssertEqual(models[0].efforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(models[0].resolved, "claude-haiku-5-5")
        XCTAssertEqual(models[0].summary, "Fastest for quick answers")
        XCTAssertNil(models[1].summary)
        XCTAssertTrue(models[1].fast)
        XCTAssertEqual(models.map(\.isAlias), [true, true, false])
        XCTAssertEqual(models[2].efforts, [])
        XCTAssertEqual(account, .init(email: "a@example.com", organization: "Acme", plan: "Claude Team"))
        XCTAssertThrowsError(try ClaudeCode.decodeCatalog(object(#"{"type":"control_response","response":{}}"#)))
    }

    func testResultReturnsStructuredOutputAsJSON() throws {
        let raw = try ClaudeCode.decodeResult(object(#"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"text":"This is a small test."}}"#))
        XCTAssertEqual(try CorrectionPolicy.decode(raw, original: "ths is a smal test."), "This is a small test.")
    }

    func testResultFailuresMapToShortMessages() throws {
        func message(_ json: String) throws -> String? {
            do { _ = try ClaudeCode.decodeResult(object(json)); return nil } catch { return error.localizedDescription }
        }
        XCTAssertEqual(try message(#"{"type":"result","subtype":"success","is_error":false,"result":"{\"text\":\"x\"}"}"#),
                       "Claude didn’t return a correction. Nothing replaced.")
        XCTAssertEqual(try message(#"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"x"}"#),
                       "Claude usage limit reached. Manage usage at claude.ai/settings/usage.")
        XCTAssertEqual(try message(#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#),
                       "Claude Code is signed out. Sign in from Settings → Providers.")
        XCTAssertEqual(try message(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}"#),
                       "Claude couldn’t correct this text. Try again.")
    }

    /// The capsule names these in a few words, so each needs its reason.
    func testFailuresCarryTheReasonTheCapsuleShows() {
        XCTAssertEqual(ClaudeCode.failure(status: 429, detail: "").reason, .limit)
        XCTAssertEqual(ClaudeCode.failure(status: nil, detail: "Not logged in · Please run /login").reason, .signIn)
        XCTAssertNil(ClaudeCode.failure(status: nil, detail: "boom").reason)
    }

    /// Runs a fake CLI script end to end: spare process, stdin draft, early return on `result`.
    func testBackendReadsResultEventFromProcess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oops-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("claude")
        // Echoes the draft back corrected, then lingers like the real CLI's shutdown.
        try #"""
        #!/bin/sh
        draft=$(cat)
        fixed=$(printf '%s' "$draft" | sed 's/ths/this/')
        printf '{"type":"system","subtype":"init"}\n'
        printf '{"type":"result","subtype":"success","is_error":false,"structured_output":{"text":"%s"}}\n' "$fixed"
        sleep 5
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let backend = ClaudeCodeBackend(runtime: .init(executable: script, directory: folder), model: "haiku", effort: "low")
        await backend.prepare()
        let started = ContinuousClock.now
        let corrected = try await backend.correct("ths works")
        XCTAssertEqual(corrected, "this works")
        XCTAssertLessThan(started.duration(to: .now), .seconds(3), "returns on the result event, not process exit")
    }

    /// Opt-in, uses the real CLI and subscription: `OOPS_LIVE_CLAUDE=1 just test --filter Live`.
    func testLiveCatalogAndCorrection() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OOPS_LIVE_CLAUDE"] == "1")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oops-claude-live")
        let runtime = try XCTUnwrap(ClaudeCodeRuntime.locate(directory: folder))
        let (status, models) = try await runtime.connect()
        guard case .signedIn = status else { return XCTFail("Claude Code is not signed in") }
        XCTAssertTrue(models.contains { $0.value == "haiku" })
        let backend = ClaudeCodeBackend(runtime: runtime, model: "haiku", effort: "low")
        await backend.prepare()
        let corrected = try await backend.correct("ths is a smal test.")
        XCTAssertEqual(corrected.lowercased(), "this is a small test.")
        // Haiku turns CRLF into LF; decode puts the draft's line endings back.
        let crlf = try await backend.correct("ths line\r\nnext line")
        XCTAssertTrue(crlf.contains("\r\n"), "line endings restored")
    }
}
