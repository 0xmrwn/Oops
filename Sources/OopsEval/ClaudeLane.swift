import Foundation
import OopsCore

/// Claude through `claude -p` with the app's own arguments (`ClaudeCode.correctionArguments`) plus
/// `--include-partial-messages`, which only adds the model's streamed deltas to the events Claude Code
/// prints. One fresh process per call, started when the call is sent: the app starts it early, as the
/// shortcut is pressed, so `harness_ms` (the CLI's own time) overstates what a user waits for.
struct ClaudeLane: Lane {
    let runtime: ClaudeCodeRuntime
    /// What `--model` takes: an alias that follows new releases.
    let model: String
    let effort: String?

    func notes() async -> [String] { [] }

    func send(_ text: String) async -> Answer {
        let surface = "claude-print-stream-json"
        let started = ContinuousClock.now
        let process: CLIProcess
        let arguments = ClaudeCode.correctionArguments(model: model, effort: effort, instructions: CorrectionPolicy.instructions)
        do { process = try CLIProcess(runtime, arguments: arguments + ["--include-partial-messages"]) }
        catch { return Answer(error: "claude: couldn't start", surface: surface, effort: effort) }
        process.finishInput(text)
        do {
            var answer = try await withDeadline(.seconds(40), orThrow: URLError(.timedOut)) { try await Self.read(process, started: started) }
            answer.surface = surface; answer.effort = effort
            process.retire()
            return answer
        } catch {
            process.end()
            let reason = (error as? URLError)?.code == .timedOut ? "deadline: no complete answer in 40 s" : "claude: stopped before answering"
            return Answer(total: milliseconds(since: started), error: reason, transient: !(error is URLError), surface: surface, effort: effort)
        }
    }

    /// Cancelling (the deadline) ends the process, which ends the read; the app's reader does the same.
    private static func read(_ process: CLIProcess, started: ContinuousClock.Instant) async throws -> Answer {
        try await withTaskCancellationHandler { try await events(process, started: started) } onCancel: { process.end() }
    }

    private static func events(_ process: CLIProcess, started: ContinuousClock.Instant) async throws -> Answer {
        var answer = Answer(surface: "")
        var total = 0
        for try await line in process.output.bytes.lines {
            total += line.utf8.count
            guard total <= 8_000_000 else { break }
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
            switch object["type"] as? String {
            case "stream_event":
                let event = object["event"] as? [String: Any] ?? [:]
                if event["type"] as? String == "message_start", let message = event["message"] as? [String: Any] {
                    answer.modelReported = message["model"] as? String ?? answer.modelReported
                    answer.requestID = message["id"] as? String ?? answer.requestID
                }
                guard event["type"] as? String == "content_block_delta", let kind = (event["delta"] as? [String: Any])?["type"] as? String else { continue }
                answer.ttft = answer.ttft ?? milliseconds(since: started)
                // The answer arrives as text or as the structured-output tool's JSON; thinking comes first.
                if kind == "text_delta" || kind == "input_json_delta" { answer.ttfc = answer.ttfc ?? milliseconds(since: started) }
            case "rate_limit_event":
                let info = object["rate_limit_info"] as? [String: Any] ?? [:]
                if info["status"] as? String == "rejected" {
                    let resets = (info["resetsAt"] as? NSNumber)?.doubleValue
                    answer.limit = LimitSignal(wait: resets.map { $0 - Date().timeIntervalSince1970 }, daily: true)
                }
            case "result":
                answer.total = milliseconds(since: started)
                decode(object, into: &answer)
                return answer
            default: continue
            }
        }
        throw CorrectionError.message("Claude Code stopped before answering.")
    }

    /// The `result` event, decoded by the app (`ClaudeCode.decodeResult`); only codes are kept from a failure.
    private static func decode(_ object: [String: Any], into answer: inout Answer) {
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        let usage = object["usage"] as? [String: Any] ?? [:]
        let input = [usage["input_tokens"], usage["cache_creation_input_tokens"], usage["cache_read_input_tokens"]].compactMap(int)
        answer.tokens = CallRecord.Tokens(in: input.isEmpty ? nil : input.reduce(0, +), out: int(usage["output_tokens"]),
                                          reasoning: int((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]),
                                          cached: int(usage["cache_read_input_tokens"]))
        answer.cost = (object["total_cost_usd"] as? NSNumber)?.doubleValue
        answer.finish = object["stop_reason"] as? String
        if let api = int(object["duration_api_ms"]), api > 0, let total = answer.total { answer.harness = max(0, total - api) }
        if answer.modelReported == nil { answer.modelReported = (object["modelUsage"] as? [String: Any])?.keys.min() }
        let status = int(object["api_error_status"])
        do {
            answer.raw = try ClaudeCode.decodeResult(object)
            answer.status = 200
        } catch {
            answer.status = status
            let reason = [object["subtype"], object["terminal_reason"]].compactMap { $0 as? String }.joined(separator: " ")
            answer.error = "claude: \(reason)" + (status.map { " HTTP \($0)" } ?? "")
            let detail = ((object["result"] as? String) ?? "").lowercased()
            if (error as? CorrectionError)?.reason == .limit {
                // A plan's usage window is spent for hours; a 429 passes in seconds.
                answer.limit = answer.limit ?? LimitSignal(wait: nil, daily: detail.contains("usage limit"))
            } else if object["is_error"] as? Bool != true && object["subtype"] as? String == "success"
                || (object["subtype"] as? String ?? "").contains("structured_output") {
                answer.malformed = true
            } else if status.map({ $0 >= 500 }) ?? false { answer.transient = true }
        }
    }
}

/// A running CLI: stdin written once and closed, stdout read as lines, stderr discarded (it can echo
/// the draft). The app's `ClaudeProcess`, with the same environment and folder.
final class CLIProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), stdout = Pipe()
    var output: FileHandle { stdout.fileHandleForReading }

    init(_ runtime: ClaudeCodeRuntime, arguments: [String]) throws {
        process.executableURL = runtime.executable
        process.arguments = arguments
        process.currentDirectoryURL = runtime.directory
        process.standardInput = input; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(["API_TIMEOUT_MS": "45000"]) { _, cap in cap }
        try process.run()
    }

    func finishInput(_ text: String) {
        let handle = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        }
    }

    func end() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [process] in if process.isRunning { kill(pid, SIGKILL) } }
    }

    /// As the app does: a few seconds to exit on its own once the answer is in.
    func retire() { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { self.end() } }
}
