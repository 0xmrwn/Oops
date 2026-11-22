import XCTest
@testable import OopsCore

final class ClaudeAgentArgumentsTests: XCTestCase {
    func testPermissionMatrix() throws {
        let cases: [(Bool, Bool, Bool, String, String)] = [
            (false, false, false, "Read,Write,Edit,StructuredOutput", "Read(./**),Write(./**),Edit(./**),StructuredOutput"),
            (true, false, false, "Read,Write,Edit,WebSearch,WebFetch,StructuredOutput", "Read(./**),Write(./**),Edit(./**),WebSearch,WebFetch,StructuredOutput"),
            (false, true, false, "Read,Write,Edit,Bash,StructuredOutput", "Read(./**),Write(./**),Edit(./**),Bash,StructuredOutput"),
            (true, true, false, "Read,Write,Edit,WebSearch,WebFetch,Bash,StructuredOutput", "Read(./**),Write(./**),Edit(./**),WebSearch,WebFetch,Bash,StructuredOutput"),
            (false, false, true, "Read,Write,Edit,Skill,StructuredOutput", "Read(./**),Write(./**),Edit(./**),Skill,StructuredOutput,Read(//a b/skills/**),Read(//linked/**)"),
            (true, false, true, "Read,Write,Edit,WebSearch,WebFetch,Skill,StructuredOutput", "Read(./**),Write(./**),Edit(./**),WebSearch,WebFetch,Skill,StructuredOutput,Read(//a b/skills/**),Read(//linked/**)"),
            (false, true, true, "Read,Write,Edit,Bash,Skill,StructuredOutput", "Read(./**),Write(./**),Edit(./**),Bash,Skill,StructuredOutput,Read(//a b/skills/**),Read(//linked/**)"),
            (true, true, true, "Read,Write,Edit,WebSearch,WebFetch,Bash,Skill,StructuredOutput", "Read(./**),Write(./**),Edit(./**),WebSearch,WebFetch,Bash,Skill,StructuredOutput,Read(//a b/skills/**),Read(//linked/**)"),
        ]
        for (web, cmd, setup, tools, allowed) in cases {
            let dirs = ["/a b/skills", "/linked"]
            let run = ActionAgentRun(model: "haiku", effort: "low", searchWeb: web, runCommands: cmd, usesSetup: setup)
            let settings = ClaudeAgent.settings(folder: "/runs/id", home: "/a b", skillDirectories: setup ? dirs : [])
            let expected: NSDictionary = [
                "disableAllHooks": true, "permissions": ["deny": ["Edit(./.claude/**)", "Write(./.claude/**)"]],
                "sandbox": ["allowUnsandboxedCommands": false, "enabled": true, "failIfUnavailable": true,
                            "filesystem": ["allowRead": setup ? ["/runs/id", "/a b/skills", "/linked"] : ["/runs/id"],
                                           "denyRead": ["/a b", "/private/var/folders", "/Volumes"]]],
            ]
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(settings.utf8)) as? NSDictionary, expected)
            let prefix = setup ? ["-p"] : ["-p", "--safe-mode"]
            let flags = prefix + ["--setting-sources=project", "--strict-mcp-config", "--permission-mode=dontAsk", "--no-session-persistence",
                                  "--output-format=stream-json", "--verbose", "--model=haiku", "--effort=low", "--tools=" + tools,
                                  "--allowedTools=" + allowed, "--settings=" + settings, "--system-prompt=instruction", "--json-schema=" + ClaudeCode.schema]
            XCTAssertEqual(ClaudeAgent.arguments(run, instructions: "instruction", settings: settings, skillDirectories: dirs), flags)
        }
    }

    func testNilModelAndEffortUseCLIDefaults() {
        let flags = ClaudeAgent.arguments(.init(), instructions: "", settings: "{}", skillDirectories: [])
        XCTAssertFalse(flags.contains { $0.hasPrefix("--model") || $0.hasPrefix("--effort") })
    }

    func testSetupAddsMemoryBeforeSkillsAndKeepsOutputContractLast() {
        let request = ActionPrompt.request(for: .typed("shorten"), draft: "draft").instructions
        let skillRule = "The instruction may name the person's skills as /name. Load each one it names with the Skill tool and follow it as part of the instruction.\n"
        let memory = String(repeating: "é", count: 32_000)
        XCTAssertEqual(ClaudeAgent.instructions(request, memory: "private", usesSkills: false), request)
        XCTAssertEqual(ClaudeAgent.instructions(request, memory: nil, usesSkills: true), skillRule + request)
        let prompt = ClaudeAgent.instructions(request, memory: memory + "truncated", usesSkills: true)
        XCTAssertEqual(prompt, "The person's own Claude Code instructions (their CLAUDE.md), for how they like work done. Follow them where they apply to this task:\n<claude-md>\n" + memory + "\n</claude-md>\n\n" + skillRule + request)
        XCTAssertTrue(prompt.hasSuffix(ActionPrompt.contract))
    }
}
