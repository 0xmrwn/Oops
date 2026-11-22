import Foundation

public struct SkillMention: Equatable, Sendable {
    public let range: Range<String.Index>, sigil: Character, name: String
}

public enum ClaudeSkills {
    public static func mentions(in text: String) -> [SkillMention] {
        var mentions = [SkillMention]()
        var index = text.startIndex
        while index < text.endIndex {
            let start = index, sigil = text[index]
            text.formIndex(after: &index)
            guard sigil == "/" || sigil == "$" else { continue }
            if start != text.startIndex {
                let before = text[text.index(before: start)]
                guard before.isWhitespace || "(\"'“‘".contains(before) else { continue }
            }
            let nameStart = index
            guard index < text.endIndex, isAlphanumeric(text[index]) else { continue }
            repeat { text.formIndex(after: &index) }
            while index < text.endIndex && (isAlphanumeric(text[index]) || "_-".contains(text[index]))
            guard index == text.endIndex || text[index].isWhitespace || ".,;:!?)\"'”’".contains(text[index]) else { continue }
            mentions.append(SkillMention(range: start..<index, sigil: sigil, name: String(text[nameStart..<index])))
        }
        return mentions
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    public static func rewrite(_ text: String, known: [String]) -> String {
        let names = Dictionary(known.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var result = "", start = text.startIndex
        for mention in mentions(in: text) {
            guard let name = names[mention.name.lowercased()] else { continue }
            result += text[start..<mention.range.lowerBound] + "/" + name
            start = mention.range.upperBound
        }
        return result + text[start...]
    }

    static func decodeNames(_ object: [String: Any]) -> [String] {
        let response = (object["response"] as? [String: Any])?["response"] as? [String: Any]
        let commands = response?["commands"] as? [[String: Any]] ?? []
        return commands.compactMap { $0["builtin"] as? Bool == true ? nil : $0["name"] as? String }
    }
}

public extension ClaudeCodeRuntime {
    func skillNames(environment: ClaudeAgentEnvironment = .live) async -> [String]? {
        guard environment.sandboxAvailable(),
              let folder = try? ClaudeAgentFolder.make(in: environment.runs, skills: environment.skills) else { return nil }
        defer { folder.remove() }
        return await ClaudeCodeRuntime(executable: executable, directory: folder.url).stagedSkillNames(environment: environment)
    }

    internal func stagedSkillNames(environment: ClaudeAgentEnvironment) async -> [String]? {
        let flags = ["-p", "--setting-sources=project", "--strict-mcp-config", "--tools=", "--permission-mode=dontAsk",
                     "--no-session-persistence", "--output-format=stream-json", "--verbose", "--input-format=stream-json",
                     #"--settings={"disableAllHooks":true}"#]
        guard !Task.isCancelled, let process = try? ClaudeAgentProcess(executable: executable, arguments: flags, folder: directory,
                                                                       environment: environment.hostEnvironment) else { return nil }
        process.send(ClaudeCode.initialize + "\n")
        let line = try? await withDeadline(environment.handshake, orThrow: ClaudeAgentError.timedOut) {
            for try await line in process.lines where ClaudeProcess.object(line)["type"] as? String == "control_response" { return line }
            throw ClaudeAgentError.stopped
        }
        await process.end(grace: environment.grace)
        guard let line else { return nil }
        let object = ClaudeProcess.object(line)
        guard let response = object["response"] as? [String: Any],
              let body = response["response"] as? [String: Any], body["commands"] is [[String: Any]] else { return nil }
        return ClaudeSkills.decodeNames(object)
    }
}
