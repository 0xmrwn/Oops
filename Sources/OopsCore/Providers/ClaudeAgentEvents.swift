import Foundation

public enum ClaudeAgentStep: Equatable, Sendable {
    case starting, thinking, searching(String), reading(String), readingResults, running, usingSkill(String)
    /// Claude Code's own few words for the tool work under way.
    case summary(String)
    case writing, done

    /// The kind of step without what it names, for the log.
    var kind: String {
        switch self {
        case .starting: "starting"
        case .thinking: "thinking"
        case .searching: "searching"
        case .reading: "reading"
        case .readingResults: "readingResults"
        case .running: "running"
        case .usingSkill: "usingSkill"
        case .summary: "summary"
        case .writing: "writing"
        case .done: "done"
        }
    }

    /// Steps a tool call stands behind, which Claude Code's summary may say more precisely.
    var isTool: Bool {
        switch self {
        case .searching, .reading, .readingResults, .running, .usingSkill, .summary: true
        default: false
        }
    }
}

enum ClaudeAgentEvent {
    case updates([ClaudeAgentUpdate]), denied(String), result([String: Any]), ignored
}

/// Claude Code's stream, a line at a time, as what the run is doing. Holds what one line can't tell: the step on show,
/// which tool calls were web searches, and when activity was last reported.
struct ClaudeAgentEvents {
    /// Answer deltas come by the dozen a second; the drop only needs to know tokens are flowing, about 6 times a second.
    static let deltaSpacing: Duration = .milliseconds(166)
    private(set) var step = ClaudeAgentStep.starting
    private var searches = Set<String>(), reported: ContinuousClock.Instant?

    mutating func read(_ line: Data, at time: ContinuousClock.Instant) -> ClaudeAgentEvent {
        let object = ClaudeProcess.object(line)
        var updates = [ClaudeAgentUpdate]()
        switch object["type"] as? String {
        case "result": return .result(object)
        case "system":
            switch object["subtype"] as? String {
            case "thinking_tokens":
                move(.thinking, &updates)
                activity(at: time, spaced: false, &updates)
            case "task_summary":
                if step.isTool, let detail = Self.trimmed(object["detail"]) { move(.summary(detail), &updates) }
            case "post_turn_summary":
                if let detail = Self.trimmed(object["status_detail"]) { updates.append(.summary(detail.prefix(1).uppercased() + detail.dropFirst())) }
            case "permission_denied":
                if let name = object["tool_name"] as? String { return .denied(name) }
            default: break
            }
        case "assistant":
            let message = object["message"] as? [String: Any]
            for block in message?["content"] as? [[String: Any]] ?? [] {
                if block["name"] as? String == "WebSearch", let id = block["id"] as? String { searches.insert(id) }
                if let step = Self.step(block) { move(step, &updates) }
            }
        case "user":
            let message = object["message"] as? [String: Any]
            let returned = (message?["content"] as? [[String: Any]] ?? []).compactMap { $0["tool_use_id"] as? String }
            let searched = returned.compactMap { searches.remove($0) }
            if !searched.isEmpty { move(.readingResults, &updates) }
        case "stream_event":
            stream(object["event"] as? [String: Any] ?? [:], at: time, &updates)
        default: break
        }
        return updates.isEmpty ? .ignored : .updates(updates)
    }

    /// Partial messages: a block's start says what comes next before the block is done, and its deltas show tokens
    /// flowing. Thinking deltas carry nothing in headless runs; `thinking_tokens` stand for them. Runs answer through
    /// StructuredOutput, so only its start is the new draft being written: a text block may be a preamble to a tool.
    private mutating func stream(_ event: [String: Any], at time: ContinuousClock.Instant, _ updates: inout [ClaudeAgentUpdate]) {
        switch event["type"] as? String {
        case "content_block_start":
            let block = event["content_block"] as? [String: Any]
            switch block?["type"] as? String {
            case "thinking": move(.thinking, &updates)
            case "tool_use" where block?["name"] as? String == "StructuredOutput": move(.writing, &updates)
            default: break
            }
        case "content_block_delta":
            let delta = (event["delta"] as? [String: Any])?["type"] as? String
            if delta == "text_delta" || delta == "input_json_delta" { activity(at: time, spaced: true, &updates) }
        default: break
        }
    }

    private mutating func move(_ next: ClaudeAgentStep, _ updates: inout [ClaudeAgentUpdate]) {
        guard next != step else { return }
        step = next
        updates.append(.step(next))
    }

    private mutating func activity(at time: ContinuousClock.Instant, spaced: Bool, _ updates: inout [ClaudeAgentUpdate]) {
        if spaced, let reported, reported.duration(to: time) < Self.deltaSpacing { return }
        reported = time
        updates.append(.activity)
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > 80 ? String(text.prefix(79)) + "…" : text
    }

    private static func step(_ block: [String: Any]) -> ClaudeAgentStep? {
        if block["type"] as? String == "thinking" { return .thinking }
        guard block["type"] as? String == "tool_use", let input = block["input"] as? [String: Any] else { return nil }
        switch block["name"] as? String {
        case "WebSearch":
            if let query = trimmed(input["query"]) { return .searching(query) }
        case "WebFetch":
            if let url = input["url"] as? String, let host = URL(string: url)?.host {
                return .reading(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            }
        case "Bash": return .running
        case "Skill":
            if let skill = input["skill"] as? String { return .usingSkill(skill) }
        default: break
        }
        return nil
    }
}
