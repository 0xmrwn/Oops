import XCTest
@testable import OopsCore

final class ClaudeAgentRunnerTests: XCTestCase {
    private let files = FileManager.default
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var record: URL { root.appendingPathComponent("record") }
    private var runs: URL { root.appendingPathComponent("runs") }
    private var home: URL { root.appendingPathComponent("a b") }
    private var environment: ClaudeAgentEnvironment {
        .init(home: home, runs: runs, sandboxAvailable: { true }, grace: .milliseconds(200), handshake: .seconds(1))
    }

    override func setUpWithError() throws {
        try files.createDirectory(at: runs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try files.removeItem(at: root)
    }

    private var pids: [pid_t] {
        let text = try? String(contentsOf: record.appendingPathExtension("pids"), encoding: .utf8)
        return (text ?? "").split(separator: "\n").compactMap { pid_t($0) }.filter { $0 > 1 }
    }

    private func runner(_ mode: FakeClaude.Mode, limit: Duration = .seconds(4), env: ClaudeAgentEnvironment? = nil) throws -> ClaudeAgentRunner {
        try ClaudeAgentRunner(executable: FakeClaude.script(mode, in: root, record: record), environment: env ?? environment, limit: limit)
    }

    private func collect(_ runner: ClaudeAgentRunner, setup: Bool = false, instruction: String = "shorten") async throws -> [ClaudeAgentUpdate] {
        let request = ClaudeAgentRequest(run: .init(usesSetup: setup), instructions: instruction, input: "<draft>$review</draft>")
        var received = [ClaudeAgentUpdate]()
        for try await update in runner.run(request) { received.append(update) }
        return received
    }

    private func assertClean(count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if try files.contentsOfDirectory(atPath: runs.path).isEmpty, pids.allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pids.count, count)
        for pid in pids { XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH, "process still alive: \(pid)") }
        XCTAssertEqual(try files.contentsOfDirectory(atPath: runs.path), [])
    }

    func testAnswerArrivesBeforeExit() async throws {
        let start = ContinuousClock.now
        let updates = try await collect(runner(.answer))
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        XCTAssertEqual(updates, [.step(.starting), .step(.thinking), .step(.searching("iana example domain")), .step(.reading("example.com")),
                                 .step(.done), .answer(#"{"text":"answer"}"#)])
        let cwd = try XCTUnwrap(String(contentsOf: record, encoding: .utf8).split(separator: "\n").first)
        XCTAssertEqual(URL(fileURLWithPath: String(cwd)).deletingLastPathComponent().path, ClaudeAgentFolder.realPath(runs))
        try await assertClean(count: 1)
    }

    func testChildReceivesOnlyAllowedEnvironment() async throws {
        var env = environment
        env.hostEnvironment = ["PATH": "/usr/bin:/bin", "UNRELATED_SECRET_KEY": "private", "CLAUDE_TEST_VALUE": "config", "ANTHROPIC_TEST_VALUE": "signin"]
        _ = try await collect(runner(.answer, env: env))
        XCTAssertEqual(try String(contentsOf: record.appendingPathExtension("env"), encoding: .utf8), "\nconfig\nsignin\n")
        try await assertClean(count: 1)
    }

    func testRunMarkerMustBeAnEntireEnvironmentEntry() {
        let entry = "OOPS_AGENT_RUN=123"
        func matches(_ environment: String) -> Bool {
            var argc: CInt = 3
            var data = Data(bytes: &argc, count: MemoryLayout<CInt>.size)
            data.append(contentsOf: ("/cli\0\0cli\0" + entry + "\0\0" + environment + "\0").utf8)
            return data.withUnsafeBytes { ProcessTree.hasEnvironmentEntry(Array(entry.utf8), in: $0) }
        }
        XCTAssertFalse(matches("OTHER=value"))
        XCTAssertFalse(matches("OTHER=" + entry))
        XCTAssertFalse(matches(entry + "4"))
        XCTAssertTrue(matches("OTHER=value\0" + entry))
    }

    func testCommandEndsAfterCLIExits() async throws {
        do { _ = try await collect(runner(.orphan)); XCTFail("Expected an incomplete run") }
        catch { XCTAssertEqual(error as? ClaudeAgentError, .stopped) }
        XCTAssertEqual(pids.count, 2)
        let command = try XCTUnwrap(pids.last)
        XCTAssertTrue(kill(command, 0) == -1 && errno == ESRCH, "command survived the run")
    }

    func testSlashOnlySkillUsesCatalogSpelling() async throws {
        _ = try await collect(runner(.answer), setup: true, instruction: "Please /Review.")
        XCTAssertTrue(try String(contentsOf: record, encoding: .utf8).contains("Please /review."))
        try await assertClean(count: 1)
    }

    private func assertTimeout(_ mode: FakeClaude.Mode, count: Int) async throws {
        let start = ContinuousClock.now
        do { _ = try await collect(runner(mode, limit: .milliseconds(400))); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? ClaudeAgentError, .timedOut) }
        try await assertClean(count: count)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testTimeout() async throws { try await assertTimeout(.slow, count: 1) }
    func testTimeoutEndsCommandGroup() async throws { try await assertTimeout(.child, count: 3) }

    func testCancellationEndsCommandGroup() async throws {
        let runner = try runner(.child)
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            defer { ready.continuation.finish() }
            for try await update in runner.run(.init(run: .init(), instructions: "shorten", input: "draft")) {
                if update == .step(.reading("example.com")) { ready.continuation.yield(()) }
            }
        }
        for await _ in ready.stream { break }
        task.cancel()
        _ = await task.result
        try await assertClean(count: 3)
    }

    func testQuitEndsCommandGroup() async throws {
        let runner = try runner(.child)
        do {
            for try await update in runner.run(.init(run: .init(), instructions: "shorten", input: "draft")) {
                if update == .step(.reading("example.com")) { ClaudeAgent.endRunningProcesses() }
            }
            XCTFail("Expected the run to stop")
        } catch { XCTAssertEqual(error as? ClaudeAgentError, .stopped) }
        try await assertClean(count: 3)
    }

    func testSweepRemovesOnlyOldRunFolders() throws {
        let stale = try ClaudeAgentFolder.make(in: runs, skills: nil)
        let fresh = try ClaudeAgentFolder.make(in: runs, skills: nil)
        let unrelated = runs.appendingPathComponent("unrelated")
        try files.createDirectory(at: unrelated, withIntermediateDirectories: false)
        for url in [unrelated, stale.url] {
            try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -601)], ofItemAtPath: url.path)
        }
        ClaudeAgentFolder.sweep(runs)
        XCTAssertFalse(files.fileExists(atPath: stale.url.path))
        XCTAssertTrue(files.fileExists(atPath: fresh.url.path))
        XCTAssertTrue(files.fileExists(atPath: unrelated.path))
    }

    func testSkillPathWithPermissionPatternStopsBeforeRun() async throws {
        let skills = home.appendingPathComponent(".claude/skills")
        let target = home.appendingPathComponent("a*")
        try files.createDirectory(at: skills, withIntermediateDirectories: true)
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: skills.appendingPathComponent("review"), withDestinationURL: target)
        do { _ = try await collect(runner(.answer), setup: true); XCTFail("Expected invalid permission rule") }
        catch { XCTAssertEqual(error as? ClaudeAgentError, .sandboxUnavailable) }
        XCTAssertFalse(files.fileExists(atPath: record.path))
        try await assertClean(count: 0)
    }

    func testUsageLimit() async throws {
        do { _ = try await collect(runner(.error)); XCTFail("Expected usage limit") }
        catch { XCTAssertEqual((error as? CorrectionError)?.reason, .limit) }
        try await assertClean(count: 1)
    }

    func testSandboxUnavailable() async throws {
        var env = environment
        env.sandboxAvailable = { false }
        do { _ = try await collect(runner(.answer, env: env)); XCTFail("Expected sandbox failure") }
        catch { XCTAssertEqual(error as? ClaudeAgentError, .sandboxUnavailable) }
        XCTAssertFalse(files.fileExists(atPath: record.path))
        try await assertClean(count: 0)
        do { _ = try await collect(runner(.noSandbox)); XCTFail("Expected sandbox failure") }
        catch { XCTAssertEqual(error as? ClaudeAgentError, .sandboxUnavailable) }
        try await assertClean(count: 1)
    }

    func testSetupStagesSkillsAndRewritesOnlyInstructions() async throws {
        let skills = home.appendingPathComponent(".claude/skills"), x = skills.appendingPathComponent("x")
        let linked = root.appendingPathComponent("linked skill")
        try files.createDirectory(at: x, withIntermediateDirectories: true)
        try files.createDirectory(at: linked, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: skills.appendingPathComponent("review"), withDestinationURL: linked)
        try "Use precise verbs.".write(to: home.appendingPathComponent(".claude/CLAUDE.md"), atomically: true, encoding: .utf8)
        _ = try await collect(runner(.answer), setup: true, instruction: "Please $review.")
        let flags = try String(contentsOf: record, encoding: .utf8)
        XCTAssertFalse(flags.contains("--safe-mode"))
        XCTAssertTrue(flags.contains("--tools=Read,Write,Edit,WebSearch,WebFetch,Skill,StructuredOutput\n"))
        XCTAssertTrue(flags.contains("Use precise verbs."))
        XCTAssertTrue(flags.contains("Please /review."))
        XCTAssertTrue(flags.contains("Read(/" + ClaudeAgentFolder.realPath(linked) + "/**)"))
        XCTAssertTrue(flags.contains(ClaudeCode.initialize))
        XCTAssertTrue(flags.contains("\nstaged\n"))
        XCTAssertTrue(files.fileExists(atPath: x.path))
        XCTAssertEqual(try String(contentsOf: record.appendingPathExtension("input"), encoding: .utf8), "<draft>$review</draft>")
        try await assertClean(count: 1)
    }
}

extension ClaudeAgentRunnerTests {
    private func liveRuntime() throws -> ClaudeCodeRuntime {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OOPS_LIVE_CLAUDE"] == "1")
        return try XCTUnwrap(ClaudeCodeRuntime.locate(directory: runs, askShell: false))
    }

    private func liveAnswer(_ instruction: String, draft: String, run: ActionAgentRun, runtime: ClaudeCodeRuntime,
                            environment: ClaudeAgentEnvironment) async throws -> (text: String, steps: [ClaudeAgentStep]) {
        let prompt = ActionPrompt.request(for: .typed(instruction), draft: draft)
        let runner = ClaudeAgentRunner(executable: runtime.executable, environment: environment)
        var steps = [ClaudeAgentStep]()
        var raw: String?
        for try await update in runner.run(.init(run: run, instructions: prompt.instructions, input: prompt.input)) {
            if case .step(let step) = update { steps.append(step) }
            if case .answer(let answer) = update { raw = answer }
        }
        XCTAssertEqual(try files.contentsOfDirectory(atPath: runs.path), [])
        return try (ActionPrompt.decode(XCTUnwrap(raw), draft: draft), steps)
    }

    func testLiveAgentRunIsConfined() async throws {
        let runtime = try liveRuntime()
        let outside = root.appendingPathComponent("outside")
        let probe = try XCTUnwrap(files.urls(for: .cachesDirectory, in: .userDomainMask).first).appendingPathComponent(UUID().uuidString)
        let token = UUID().uuidString
        try token.write(to: probe, atomically: true, encoding: .utf8)
        defer { try? files.removeItem(at: probe) }
        var env = ClaudeAgentEnvironment.live
        env.runs = runs
        let outsidePath = ClaudeAgentFolder.realPath(root) + "/outside"
        let probePath = ClaudeAgentFolder.realPath(probe)
        let receipt = UUID().uuidString
        let observed = expectation(description: "finished tool calls")
        env.observeResult = { folder, refusals in
            XCTAssertTrue(refusals.contains(.init(tool: "Write", path: outsidePath)))
            XCTAssertTrue(refusals.contains(.init(tool: "Read", path: probePath)))
            XCTAssertEqual(try? String(contentsOf: folder.appendingPathComponent("receipt.txt"), encoding: .utf8), receipt)
            observed.fulfill()
        }
        let instruction = """
        Use Write to create receipt.txt in the current directory containing exactly \(receipt) with no newline.
        Then use Write at \(outsidePath) and Read at \(probePath). Attempt all three even if a tool refuses.
        Also try to read \(probePath) using cat with Bash.
        If the outside file is readable, quote its contents. Otherwise return the draft unchanged.
        """
        let answer = try await liveAnswer(instruction, draft: "Keep this sentence.", run: .init(model: "haiku", effort: "low", searchWeb: false, runCommands: true),
                                          runtime: runtime, environment: env)
        await fulfillment(of: [observed], timeout: 1)
        XCTAssertFalse(files.fileExists(atPath: outside.path))
        XCTAssertFalse(answer.text.contains(token))
        XCTAssertEqual(answer.text, "Keep this sentence.")
    }

    func testLiveSkillCanReadItsFile() async throws {
        let runtime = try liveRuntime()
        let skills = home.appendingPathComponent(".claude/skills")
        let target = root.appendingPathComponent("fixture skill")
        try files.createDirectory(at: skills, withIntermediateDirectories: true)
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: skills.appendingPathComponent("quote-file"), withDestinationURL: target)
        try "---\nname: quote-file\ndescription: Quote the reference file.\n---\nUse Read to open reference.txt in this skill's directory. Return its contents."
            .write(to: target.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let token = UUID().uuidString
        try token.write(to: target.appendingPathComponent("reference.txt"), atomically: true, encoding: .utf8)
        let names = await runtime.skillNames(environment: environment)
        XCTAssertTrue(try XCTUnwrap(names).contains("quote-file"))
        let answer = try await liveAnswer("/quote-file", draft: "Replace this.",
                                          run: .init(model: "haiku", effort: "low", searchWeb: false, usesSetup: true), runtime: runtime, environment: environment)
        XCTAssertTrue(answer.steps.contains(.usingSkill("quote-file")))
        XCTAssertEqual(answer.text, token)
    }
}
