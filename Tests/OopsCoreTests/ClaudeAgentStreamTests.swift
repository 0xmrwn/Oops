import Foundation
import Testing
@testable import OopsCore

/// A run as Claude Code streams it with partial messages, trimmed from a real capture: two web searches, then the
/// answer through StructuredOutput.
struct ClaudeAgentStreamTests {
    private static let run: [(Double, String)] = [
        (0.3, #"{"type":"system","subtype":"init"}"#),
        (0.3, #"{"type":"system","subtype":"status","status":"requesting"}"#),
        (1.0, #"{"type":"stream_event","event":{"type":"message_start","message":{"content":[]}}}"#),
        (1.0, #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#),
        (1.4, #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50}"#),
        (1.4, #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}}"#),
        (2.2, #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":200}"#),
        (2.2, #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#),
        (2.2, #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"s1","name":"WebSearch","input":{}}}}"#),
        (2.2, #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"iana"}}}"#),
        (2.5, #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" example"}}}"#),
        (2.6, #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" domain\"}"}}}"#),
        (2.7, #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"WebSearch","input":{"query":"iana example domain"}}]}}"#),
        (3.2, #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s2","name":"WebSearch","input":{"query":"example domain history"}}]}}"#),
        (3.2, #"{"type":"stream_event","event":{"type":"message_stop"}}"#),
        (3.2, #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#),
        (3.2, #"{"type":"system","subtype":"task_summary","detail":" Searching for the history of example domains… "}"#),
        (9.3, #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"s1","type":"tool_result","content":"Web search results"}]}}"#),
        (10.0, #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"s2","type":"tool_result","content":"Web search results"}]}}"#),
        (10.0, #"{"type":"system","subtype":"status","status":"requesting"}"#),
        (10.7, #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#),
        (11.1, #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":50}"#),
        (26.6, #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#),
        (26.6, #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"o1","name":"StructuredOutput","input":{}}}}"#),
        (26.6, #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"text\": \"IANA"}}}"#),
        (26.7, #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" keeps it.\"}"}}}"#),
        (31.6, #"{"type":"system","subtype":"post_turn_summary","status_category":"completed","status_detail":"answered with the domain's history"}"#),
        (34.5, #"{"type":"result","subtype":"success","is_error":false,"structured_output":{"text":"IANA keeps it."},"permission_denials":[]}"#),
        (34.5, #"{"type":"system","subtype":"task_summary","detail":null}"#),
    ]

    @Test func `a run reads as what really happened, with activity while tokens flow`() throws {
        let start = ContinuousClock.now
        var events = ClaudeAgentEvents(), updates = [ClaudeAgentUpdate](), answer: String?
        for (seconds, line) in Self.run {
            switch events.read(Data(line.utf8), at: start + .milliseconds(Int(seconds * 1000))) {
            case .updates(let list): updates += list
            case .result(let object): answer = try ClaudeAgent.decodeResult(object).raw
            case .denied, .ignored: break
            }
        }
        #expect(updates == [
            .step(.thinking), .activity, .activity, .activity,
            .step(.searching("iana example domain")), .step(.searching("example domain history")),
            .step(.summary("Searching for the history of example domains…")), .step(.readingResults),
            .step(.thinking), .activity, .step(.writing), .activity, .summary("Answered with the domain's history"),
        ])
        #expect(answer == #"{"text":"IANA keeps it."}"#)
    }

    @Test func `a summary only stands in for a tool, and a fetch's result isn't a search's`() {
        var events = ClaudeAgentEvents()
        let summary = #"{"type":"system","subtype":"task_summary","detail":"Reading the page"}"#
        _ = events.read(Data(#"{"type":"system","subtype":"thinking_tokens"}"#.utf8), at: .now)
        _ = events.read(Data(summary.utf8), at: .now)
        #expect(events.step == .thinking)
        _ = events.read(Data(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"f1","name":"WebFetch","input":{"url":"https://example.com"}}]}}"#.utf8), at: .now)
        _ = events.read(Data(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"f1"}]}}"#.utf8), at: .now)
        #expect(events.step == .reading("example.com"))
        _ = events.read(Data(summary.utf8), at: .now)
        #expect(events.step == .summary("Reading the page"))
    }

    @Test func `a text preamble before a search is activity, not the draft being written`() {
        let start = ContinuousClock.now
        var events = ClaudeAgentEvents(), updates = [ClaudeAgentUpdate]()
        let lines = [
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me look that up."}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look that up."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"WebSearch","input":{"query":"iana example domain"}}]}}"#,
        ]
        for line in lines {
            if case .updates(let list) = events.read(Data(line.utf8), at: start) { updates += list }
        }
        #expect(updates == [.activity, .step(.searching("iana example domain"))])
    }

    @Test func `answer deltas report activity about six times a second`() {
        let start = ContinuousClock.now
        var events = ClaudeAgentEvents(), count = 0
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"a"}}}"#
        for tick in 0 ..< 100 {
            if case .updates(let list) = events.read(Data(delta.utf8), at: start + .milliseconds(tick * 10)) { count += list.count }
        }
        #expect(count == 6)
    }
}
