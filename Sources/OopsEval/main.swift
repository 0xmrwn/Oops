import Foundation
import OopsCore

let usage = """
oops-eval: build eval sets from Oops's debug log and score models and prompts on them.

  oops-eval export [--log DIR] [--out FILE] [--include-try] [--include-invalid] [--redact]
      Debug log → eval corpus (JSONL). Kept corrections become expected answers, reverted ones
      rejected answers. --log defaults to ~/Library/Application Support/oops/Debug.

  oops-eval finetune --corpus FILE [--out FILE] [--rules FILE]
      Corpus → chat-format training lines (system, user, assistant) from cases with a known answer.

  oops-eval run --corpus FILE --provider echo|claude|api|chatgpt [--model ID] [--effort LEVEL]
                [--base-url URL] [--key-env NAME] [--rules FILE] [--jobs N] [--out FILE] [--json]
      Corrects every case with the app's own prompt, decoding and validation, then scores it.
      --rules replaces the correction rules (the contract is always appended), for prompt
      hill-climbing. Summary on stdout (--json for JSON), per-case results to --out.

  oops-eval replay [--log DIR | --answers FILE] [--json]
      Decodes logged model answers again with today's rules and compares them with the strict
      all-or-nothing check: how many become usable, whole or in part, without calling a model.
      --answers takes JSONL lines with `input` and `raw` (the model's JSON answer), such as
      `run --out` results.

  oops-eval lanes --cases FILE --run NAME [--config FILE] [--attempts K] [--only NAMES] [--limit N]
                  [--env-file FILE] [--runs DIR] [--retry-errors] [--retry-deferred] [--dry-run]
      Every lane of the config (default fixtures/eval/lanes.json) over the cases, k attempts each, into
      DIR/NAME (default ~/Library/Application Support/oops-eval/runs): one record per call, written as
      it finishes, and manifest.json. Rerunning sends only what has no record yet; --retry-errors
      also resends errors; --retry-deferred sends deferred lanes before their reset. --only takes provider names or model IDs, comma-separated. --env-file
      loads the keys the config names, without printing them. See docs/eval.md.

  oops-eval report --run NAME [--runs DIR] [--json]
      Per lane: valid rate, p50/p95 total time and time to first token, errors, rate limits, pace.

Examples:
  oops-eval export --out corpus.jsonl
  oops-eval run --corpus corpus.jsonl --provider claude --model haiku --effort low --out haiku.jsonl
  oops-eval run --corpus corpus.jsonl --provider api --base-url http://localhost:1234/v1 --model qwen3-4b
  oops-eval lanes --cases fixtures/corpus/stress.jsonl --run shakedown-1 --attempts 1 --env-file .env
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("oops-eval: \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !["-h", "--help", "help"].contains(command) else { print(usage); exit(0) }
arguments.removeFirst()

var options: [String: String] = [:]
var flags = Set<String>()
let switches: Set<String> = ["--include-try", "--include-invalid", "--redact", "--json", "--retry-errors", "--retry-deferred", "--dry-run"]
while let argument = arguments.first {
    arguments.removeFirst()
    guard argument.hasPrefix("--") else { fail("unexpected argument \(argument)") }
    if switches.contains(argument) { flags.insert(argument); continue }
    guard let value = arguments.first else { fail("\(argument) needs a value") }
    arguments.removeFirst(); options[argument] = value
}

func path(_ value: String) -> URL { URL(fileURLWithPath: (value as NSString).expandingTildeInPath) }
@MainActor func output(_ name: String, default fallback: String) -> URL { path(options[name] ?? fallback) }

/// `--rules` lives in the registration domain, which is never written to disk.
if let rules = options["--rules"] {
    guard let text = try? String(contentsOf: path(rules), encoding: .utf8) else { fail("can't read \(rules)") }
    UserDefaults.standard.register(defaults: [CorrectionPolicy.customRulesKey: text])
}

switch command {
case "export":
    let store = DebugLogStore(directory: options["--log"].map(path) ?? DebugLogStore.defaultDirectory)
    let cases = Corpus.export(store.entries(), options: .init(includeTry: flags.contains("--include-try"),
                                                               includeInvalid: flags.contains("--include-invalid"),
                                                               redact: flags.contains("--redact")))
    let url = output("--out", default: "corpus.jsonl")
    do { try Corpus.write(cases, to: url) } catch { fail(error.localizedDescription) }
    let labels = Dictionary(grouping: cases, by: \.label.rawValue).mapValues(\.count).sorted { $0.key < $1.key }
    print("\(cases.count) cases → \(url.path) (\(labels.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))")

case "finetune":
    guard let corpus = options["--corpus"] else { fail("finetune needs --corpus") }
    do {
        let lines = try Corpus.fineTuning(try Corpus.read(path(corpus)), instructions: CorrectionPolicy.instructions)
        let url = output("--out", default: "finetune.jsonl")
        try lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }.write(to: url, options: .atomic)
        print("\(lines.count) examples → \(url.path)")
    } catch { fail(error.localizedDescription) }

case "run":
    guard let corpus = options["--corpus"], let provider = options["--provider"] else { fail("run needs --corpus and --provider") }
    let cases: [EvalCase]
    do { cases = try Corpus.read(path(corpus)) } catch { fail("can't read \(corpus): \(error.localizedDescription)") }
    let model = options["--model"] ?? ""
    let backend: any CorrectionBackend
    switch provider {
    case "echo": backend = EchoBackend()
    case "claude":
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oops-eval-claude")
        guard let runtime = ClaudeCodeRuntime.locate(directory: directory) else { fail("Claude Code isn't installed") }
        backend = ClaudeCodeBackend(runtime: runtime, model: model.isEmpty ? "haiku" : model, effort: options["--effort"])
    case "api":
        guard let base = options["--base-url"].flatMap(URL.init(string:)), !model.isEmpty else { fail("api needs --base-url and --model") }
        let key = options["--key-env"].flatMap { ProcessInfo.processInfo.environment[$0] } ?? ""
        backend = OpenAICompatibleBackend(configuration: APIConfiguration(baseURL: base, model: model, apiKey: key, reasoningEffort: options["--effort"]))
    case "chatgpt":
        // Reads Oops's saved sign-in; macOS asks once before sharing its Keychain item.
        let auth = ChatGPTAuth(openBrowser: { _ in throw CorrectionError.message("Sign in to ChatGPT in Oops first.") })
        backend = ChatGPTBackend(auth: auth, model: model.isEmpty ? "gpt-6-luna" : model, effort: options["--effort"] ?? "low")
    default: fail("unknown provider \(provider)")
    }
    let jobs = Int(options["--jobs"] ?? "") ?? 1
    let total = cases.count
    let terminal = isatty(STDERR_FILENO) == 1
    let results = await Runner.run(cases, backend: backend, jobs: jobs) { done in
        if terminal { FileHandle.standardError.write(Data("\r\(done)/\(total)".utf8)) }
    }
    if terminal { FileHandle.standardError.write(Data("\n".utf8)) }
    if let out = options["--out"] {
        do { try Corpus.write(results, to: path(out)) } catch { fail(error.localizedDescription) }
    }
    let summary = Summary(results, cases: cases, model: provider + (model.isEmpty ? "" : "/" + model))
    if flags.contains("--json") {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: (try? encoder.encode(summary)) ?? Data(), as: UTF8.self))
    } else { print(summary.text) }

case "replay":
    let answers: [Replay.Answer]
    if let file = options["--answers"] {
        guard let data = try? Data(contentsOf: path(file)) else { fail("can't read \(file)") }
        // Lines without an answer (a run's errors) are skipped.
        answers = data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(Replay.Answer.self, from: Data($0)) }
    } else {
        answers = Replay.answers(in: DebugLogStore(directory: options["--log"].map(path) ?? DebugLogStore.defaultDirectory).entries())
    }
    let replay = Replay(answers)
    if flags.contains("--json") {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: (try? encoder.encode(replay)) ?? Data(), as: UTF8.self))
    } else { print(replay.text) }

case "lanes":
    guard let cases = options["--cases"], let run = options["--run"] else { fail("lanes needs --cases and --run") }
    let configURL = path(options["--config"] ?? "fixtures/eval/lanes.json")
    if let env = options["--env-file"] {
        guard let config = try? LanesConfig.read(configURL) else { fail("can't read \(configURL.path)") }
        do { try loadEnvironment(path(env), names: config.environmentNames) } catch { fail("can't read \(env)") }
    }
    let harness = Harness(options: .init(run: run, runs: output("--runs", default: Harness.defaultRuns), cases: path(cases), config: configURL,
                                         attempts: options["--attempts"].flatMap { Int($0) },
                                         only: options["--only"].map { Set($0.split(separator: ",").map(String.init)) },
                                         limit: options["--limit"].flatMap { Int($0) },
                                         retryErrors: flags.contains("--retry-errors"), retryDeferred: flags.contains("--retry-deferred"), dryRun: flags.contains("--dry-run")))
    do {
        let manifest = try await harness.run()
        if !flags.contains("--dry-run") {
            print(LaneReport.table(try LaneReport.make(output("--runs", default: Harness.defaultRuns).appendingPathComponent(manifest.run))))
        }
    } catch { fail(error.localizedDescription) }

case "report":
    guard let run = options["--run"] else { fail("report needs --run") }
    do {
        let reports = try LaneReport.make(output("--runs", default: Harness.defaultRuns).appendingPathComponent(run))
        if flags.contains("--json") {
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(reports), as: UTF8.self))
        } else { print(LaneReport.table(reports)) }
    } catch { fail(error.localizedDescription) }

default:
    fail("unknown command \(command); see oops-eval --help")
}
