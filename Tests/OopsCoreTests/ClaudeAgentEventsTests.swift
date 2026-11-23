import XCTest
@testable import OopsCore

final class ClaudeAgentEventsTests: XCTestCase {
    private func event(_ json: String) -> ClaudeAgentEvent {
        var events = ClaudeAgentEvents()
        return events.read(Data(json.utf8), at: .now)
    }

    private func steps(_ json: String) -> [ClaudeAgentStep]? {
        guard case .updates(let updates) = event(json) else { return nil }
        return updates.compactMap { if case .step(let step) = $0 { step } else { nil } }
    }

    func testProgress() {
        let cases: [(String, ClaudeAgentStep)] = [
            (#"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50}"#, .thinking),
            (#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#, .thinking),
            (#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"thinking","thinking":""}}}"#, .thinking),
            (#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#, .writing),
            (#"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"StructuredOutput","input":{}}}}"#, .writing),
            (tool("WebSearch", #"{"query":" query "}"#), .searching("query")),
            (tool("WebSearch", #"{"query":""# + String(repeating: "x", count: 81) + #""}"#), .searching(String(repeating: "x", count: 79) + "…")),
            (tool("WebFetch", #"{"url":"https://www.example.com/path"}"#), .reading("example.com")),
            (tool("Bash", "{}"), .running), (tool("Skill", #"{"skill":"review","args":"brief"}"#), .usingSkill("review")),
        ]
        for (json, expected) in cases { XCTAssertEqual(steps(json), [expected], json) }
    }

    func testMixedContentReportsEachStepInOrder() {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"thinking"},{"type":"text","text":"working"},
        {"type":"tool_use","name":"Bash","input":{}},{"type":"tool_use","name":"WebSearch","input":{"query":"query"}},
        {"type":"tool_use","name":"WebFetch","input":{"url":"https://example.org"}},
        {"type":"tool_use","name":"Skill","input":{"skill":"review"}}]}}
        """
        XCTAssertEqual(steps(json), [.thinking, .running, .searching("query"), .reading("example.org"), .usingSkill("review")])
    }

    private func tool(_ name: String, _ input: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"\#(name)","input":\#(input)}]}}"#
    }

    func testDenialsAndResult() throws {
        guard case .denied("Write") = event(#"{"type":"system","subtype":"permission_denied","tool_name":"Write"}"#),
              case .result(let object) = event(#"{"type":"result","subtype":"success","structured_output":{"text":"answer"},"permission_denials":[{"tool_name":"Write","tool_input":{"file_path":"/outside"}}]}"#)
        else { return XCTFail("Missing denial or result") }
        let answer = try ClaudeAgent.decodeResult(object)
        XCTAssertEqual(answer.raw, #"{"text":"answer"}"#)
        XCTAssertEqual(answer.refused, [.init(tool: "Write", path: "/outside")])
    }

    func testUnrelatedEvents() {
        let ignored = ["not json", #"{"type":"system","subtype":"init"}"#, #"{"type":"system","subtype":"task_summary"}"#,
                       #"{"type":"system","subtype":"status","status":"requesting"}"#, #"{"type":"rate_limit_event"}"#,
                       #"{"type":"system","subtype":"post_turn_summary","status_detail":" "}"#,
                       #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":""}}}"#,
                       #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"WebSearch","input":{}}}}"#,
                       #"{"type":"stream_event","event":{"type":"message_stop"}}"#] + ["Read", "Write", "Edit", "StructuredOutput"].map { tool($0, "{}") }
        for json in ignored {
            guard case .ignored = event(json) else { XCTFail(json); continue }
        }
    }

    func testResultFailures() {
        for subtype in ["success", "error_max_structured_output_retries"] {
            XCTAssertThrowsError(try ClaudeAgent.decodeResult(["subtype": subtype, "result": "commentary"])) {
                XCTAssertEqual($0 as? ActionOutputError, .malformed)
            }
        }
        XCTAssertThrowsError(try ClaudeAgent.decodeResult(["is_error": true, "api_error_status": 403])) {
            XCTAssertEqual(($0 as? CorrectionError)?.reason, .signIn)
        }
        XCTAssertThrowsError(try ClaudeAgent.decodeResult(["is_error": true, "result": "unexpected"])) {
            XCTAssertEqual($0 as? ClaudeAgentError, .stopped)
        }
    }
}
