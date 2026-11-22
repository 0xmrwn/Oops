import XCTest
@testable import OopsCore

final class ClaudeAgentEventsTests: XCTestCase {
    private func event(_ json: String) -> ClaudeAgentEvent { ClaudeAgentEvents.decode(Data(json.utf8)) }

    func testProgress() {
        let cases: [(String, ClaudeAgentStep)] = [
            (#"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50}"#, .thinking),
            (#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#, .thinking),
            (tool("WebSearch", #"{"query":" query "}"#), .searching("query")),
            (tool("WebSearch", #"{"query":""# + String(repeating: "x", count: 81) + #""}"#), .searching(String(repeating: "x", count: 79) + "…")),
            (tool("WebFetch", #"{"url":"https://www.example.com/path"}"#), .reading("example.com")),
            (tool("Bash", "{}"), .running), (tool("Skill", #"{"skill":"review","args":"brief"}"#), .usingSkill("review")),
        ]
        for (json, expected) in cases {
            guard case .steps(let steps) = event(json) else { XCTFail(json); continue }
            XCTAssertEqual(steps, [expected])
        }
    }

    func testMixedContentReportsEachStepInOrder() {
        let json = """
        {"type":"assistant","message":{"content":[{"type":"thinking"},{"type":"text","text":"working"},
        {"type":"tool_use","name":"Bash","input":{}},{"type":"tool_use","name":"WebSearch","input":{"query":"query"}},
        {"type":"tool_use","name":"WebFetch","input":{"url":"https://example.org"}},
        {"type":"tool_use","name":"Skill","input":{"skill":"review"}}]}}
        """
        guard case .steps(let steps) = event(json) else { return XCTFail("Missing steps") }
        XCTAssertEqual(steps, [.thinking, .running, .searching("query"), .reading("example.org"), .usingSkill("review")])
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
                       #"{"type":"rate_limit_event"}"#] + ["Read", "Write", "Edit", "StructuredOutput"].map { tool($0, "{}") }
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
