import Foundation

public enum ClaudeAgentError: Error, Equatable, Sendable {
    case sandboxUnavailable, timedOut, notInstalled, stopped
}

/// Claude Code run as an agent for one action, confined so that it only returns text: its tools come from the
/// action's switches, its file tools reach no further than the run's own folder, its shell is sandboxed, and none of
/// the person's settings, hooks or connected tools load.
public enum ClaudeAgent {
    /// How long a run may take before it is ended. Not a setting.
    public static let limit: Duration = .seconds(300)

    /// Only project settings load, and the run's folder has none, so the person's own permission rules can never
    /// widen a run; `--settings` then adds the sandbox. `=` forms throughout: the variadic flags would swallow what
    /// follows them.
    public static func arguments(_ run: ActionAgentRun, instructions: String, settings: String, skillDirectories: [String]) -> [String] {
        var flags = ["-p"]
        if !run.usesSetup { flags.append("--safe-mode") }
        flags += ["--setting-sources=project", "--strict-mcp-config", "--permission-mode=dontAsk",
                  "--no-session-persistence", "--output-format=stream-json", "--verbose", "--include-partial-messages"]
        if let model = run.model { flags.append("--model=" + model) }
        if let effort = run.effort { flags.append("--effort=" + effort) }
        var extras = [String]()
        if run.searchWeb { extras += ["WebSearch", "WebFetch"] }
        if run.runCommands { extras.append("Bash") }
        if run.usesSetup { extras.append("Skill") }
        extras.append("StructuredOutput")
        let tools = ["Read", "Write", "Edit"] + extras
        var allowed = ["Read(./**)", "Write(./**)", "Edit(./**)"] + extras
        if run.usesSetup { allowed += skillDirectories.map { "Read(/" + $0 + "/**)" } }
        return flags + ["--tools=" + tools.joined(separator: ","), "--allowedTools=" + allowed.joined(separator: ","),
                        "--settings=" + settings, "--system-prompt=" + instructions, "--json-schema=" + ClaudeCode.schema]
    }

    /// The sandbox every run gets: no unsandboxed fallback, the home folder and other volumes unreadable to commands
    /// apart from the run's folder and the skills it was given, and no hooks.
    public static func settings(folder: String, home: String, skillDirectories: [String]) -> String {
        let filesystem = ["allowRead": [folder] + skillDirectories, "denyRead": [home, "/private/var/folders", "/Volumes"]]
        let settings: [String: Any] = ["disableAllHooks": true, "permissions": ["deny": ["Edit(./.claude/**)", "Write(./.claude/**)"]],
                                       "sandbox": ["enabled": true, "failIfUnavailable": true, "allowUnsandboxedCommands": false, "filesystem": filesystem]]
        // Only strings, arrays, dictionaries and booleans enter these settings. Never launch with empty settings.
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            preconditionFailure("Invalid sandbox settings")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// With the person's setup on, their instruction file goes in as text: loading it the usual way would bring their
    /// settings with it.
    public static func instructions(_ request: String, memory: String?, usesSkills: Bool) -> String {
        guard usesSkills else { return request }
        var prefix = ""
        if let memory {
            prefix = "The person's own Claude Code instructions (their CLAUDE.md), for how they like work done. Follow them where they apply to this task:\n"
                + "<claude-md>\n" + memory.prefix(32_000) + "\n</claude-md>\n\n"
        }
        return prefix + "The instruction may name the person's skills as /name. Load each one it names with the Skill tool and follow it as part of the instruction.\n" + request
    }

    struct Refusal: Equatable, Sendable {
        let tool: String, path: String?
    }

    static func decodeResult(_ object: [String: Any]) throws -> (raw: String, refused: [Refusal]) {
        let subtype = object["subtype"] as? String
        if subtype == "error_max_structured_output_retries" { throw ActionOutputError.malformed }
        if object["is_error"] as? Bool == true {
            let failure = ClaudeCode.failure(status: object["api_error_status"] as? Int, detail: object["result"] as? String ?? "")
            if failure.reason != nil { throw failure }
            throw ClaudeAgentError.stopped
        }
        guard subtype == "success" else { throw ClaudeAgentError.stopped }
        guard let structured = object["structured_output"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: structured) else { throw ActionOutputError.malformed }
        let denials = object["permission_denials"] as? [[String: Any]] ?? []
        return (String(decoding: data, as: UTF8.self), denials.compactMap { denial in
            guard let tool = denial["tool_name"] as? String else { return nil }
            let input = denial["tool_input"] as? [String: Any]
            return Refusal(tool: tool, path: input?["file_path"] as? String)
        })
    }

    public static func endRunningProcesses() { ClaudeAgentProcess.endAll() }
}
