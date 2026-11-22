import Foundation

public enum ClaudeAgentStep: Equatable, Sendable {
    case starting, thinking, searching(String), reading(String), running, usingSkill(String), done
}

enum ClaudeAgentEvent {
    case steps([ClaudeAgentStep]), denied(String), result([String: Any]), ignored
}

enum ClaudeAgentEvents {
    static func decode(_ line: Data) -> ClaudeAgentEvent {
        let object = ClaudeProcess.object(line)
        switch object["type"] as? String {
        case "result": return .result(object)
        case "system":
            switch object["subtype"] as? String {
            case "thinking_tokens": return .steps([.thinking])
            case "permission_denied":
                if let name = object["tool_name"] as? String { return .denied(name) }
            default: break
            }
        case "assistant":
            let message = object["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []
            let steps = blocks.compactMap(step)
            return steps.isEmpty ? .ignored : .steps(steps)
        default: break
        }
        return .ignored
    }

    private static func step(_ block: [String: Any]) -> ClaudeAgentStep? {
        if block["type"] as? String == "thinking" { return .thinking }
        guard block["type"] as? String == "tool_use", let input = block["input"] as? [String: Any] else { return nil }
        switch block["name"] as? String {
        case "WebSearch":
            if let query = input["query"] as? String {
                let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                return .searching(text.count > 80 ? String(text.prefix(79)) + "…" : text)
            }
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
