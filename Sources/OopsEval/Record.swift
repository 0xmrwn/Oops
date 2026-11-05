import Foundation

/// One call, as the Result section of `fixtures/eval/README.md` defines it: every field always
/// written, null when unknown, keys sorted so lines diff cleanly.
struct CallRecord: Codable, Sendable {
    struct Tokens: Codable, Sendable {
        var `in`: Int?, out: Int?, reasoning: Int?, cached: Int?
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(`in`, forKey: .in); try c.encode(out, forKey: .out)
            try c.encode(reasoning, forKey: .reasoning); try c.encode(cached, forKey: .cached)
        }
    }

    struct Checks: Codable, Sendable {
        var valid: Bool
        var protectedKept: Bool?, cleanUnchanged: Bool?, langKept: Bool?
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(valid, forKey: .valid); try c.encode(protectedKept, forKey: .protectedKept)
            try c.encode(cleanUnchanged, forKey: .cleanUnchanged); try c.encode(langKept, forKey: .langKept)
        }
    }

    var run: String
    var dataset: String?
    var prompt: String
    var lane: String
    var provider: String
    var model: String
    var modelReported: String?
    var effort: String?
    var surface: String
    var `case`: String
    var attempt: Int
    var started: String
    var queuedMs: Int
    var ttftMs: Int?
    var ttfcMs: Int?
    var totalMs: Int?
    var harnessMs: Int?
    var status: Int?
    var rateLimited: Int
    var retries: Int
    var finish: String?
    var requestId: String?
    var tokens: Tokens?
    var costUsd: Double?
    var raw: String?
    var output: String?
    var verdict: String
    var checks: Checks
    var error: String?
    /// Entire call lifecycle, including failed sends, backoff and provider pacing.
    var elapsedMs: Int? = nil
    var droppedEdits: Int? = nil

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(run, forKey: .run); try c.encode(dataset, forKey: .dataset); try c.encode(prompt, forKey: .prompt)
        try c.encode(lane, forKey: .lane); try c.encode(provider, forKey: .provider); try c.encode(model, forKey: .model)
        try c.encode(modelReported, forKey: .modelReported); try c.encode(effort, forKey: .effort)
        try c.encode(surface, forKey: .surface); try c.encode(`case`, forKey: .case); try c.encode(attempt, forKey: .attempt)
        try c.encode(started, forKey: .started); try c.encode(queuedMs, forKey: .queuedMs); try c.encode(ttftMs, forKey: .ttftMs)
        try c.encode(ttfcMs, forKey: .ttfcMs); try c.encode(totalMs, forKey: .totalMs); try c.encode(harnessMs, forKey: .harnessMs)
        try c.encode(status, forKey: .status); try c.encode(rateLimited, forKey: .rateLimited); try c.encode(retries, forKey: .retries)
        try c.encode(finish, forKey: .finish); try c.encode(requestId, forKey: .requestId); try c.encode(tokens, forKey: .tokens)
        try c.encode(costUsd, forKey: .costUsd); try c.encode(raw, forKey: .raw); try c.encode(output, forKey: .output)
        try c.encode(verdict, forKey: .verdict); try c.encode(checks, forKey: .checks); try c.encode(error, forKey: .error)
        try c.encodeIfPresent(elapsedMs, forKey: .elapsedMs); try c.encodeIfPresent(droppedEdits, forKey: .droppedEdits)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// `2026-10-29T09:12:03.120Z`.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }
}

/// A results file, appended to as each call finishes so a reader sees the run as it goes.
actor ResultsFile {
    let url: URL
    private var handle: FileHandle?

    init(_ url: URL) { self.url = url }

    /// The records already there, one per case and attempt; `dropping` rewrites the file without the
    /// records it matches, so they run again.
    static func existing(_ url: URL, dropping: (CallRecord) -> Bool = { _ in false }, rewrite: Bool = true) throws -> [CallRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var kept: [CallRecord] = [], removed = false
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            guard let record = try? CallRecord.decoder.decode(CallRecord.self, from: Data(line)) else {
                if index == lines.count - 1, data.last != 0x0A { continue }
                throw CocoaError(.fileReadCorruptFile)
            }
            if dropping(record) { removed = true } else { kept.append(record) }
        }
        if removed, rewrite {
            var out = Data()
            for record in kept { out.append(try CallRecord.encoder.encode(record)); out.append(0x0A) }
            try out.write(to: url, options: .atomic)
        }
        return kept
    }

    func append(_ record: CallRecord) throws {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try FileHandle(forUpdating: url)
            _ = try Self.existing(url)
            // Only an unterminated final record can be an interrupted write; completed corruption is fatal.
            let data = try Data(contentsOf: url)
            if let handle, !data.isEmpty, data.last != 0x0A {
                let start = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
                if (try? CallRecord.decoder.decode(CallRecord.self, from: Data(data[start...]))) == nil {
                    try handle.truncate(atOffset: UInt64(start))
                } else {
                    try handle.seekToEnd(); try handle.write(contentsOf: Data([0x0A]))
                }
            }
        }
        guard let handle else { return }
        var line = try CallRecord.encoder.encode(record)
        line.append(0x0A)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func close() { try? handle?.close(); handle = nil }
}

/// `runs/<run>/manifest.json`: what ran, on what, and how fast each provider was paced.
struct Manifest: Codable {
    struct Lane: Codable {
        var lane: String
        var provider: String
        /// As configured (`latest:haiku`), and what it resolved to.
        var model: String
        var resolved: String
        var effort: String?
        var surface: String?
        var streaming: Bool?
        var file: String
        var state: String
        /// How the lane settled: streaming refused, an effort level rejected, a model not found.
        var notes: [String] = []
        var records: Int = 0
        var deferred: Int = 0
        var deferredUntil: Date?
        /// Why the lane stopped early (its records couldn't be written).
        var failure: String?
    }

    struct Provider: Codable {
        var lane: String
        var documented: [String: String]?
        var pace: LanesConfig.Pace
        var achieved: Achieved?
    }

    /// This session's requests (retries included) over the time from the first send to the last answer.
    struct Achieved: Codable {
        var requests: Int
        var rateLimited: Int
        var waitedS: Double
        var minutes: Double
        var perMinute: Double?
    }

    struct Session: Codable {
        var id: String?
        var started: Date
        var finished: Date?
        var sent: Int = 0
    }

    var run: String
    var cases: String
    var datasets: [String]
    var prompt: String
    var attempts: Int
    var created: Date
    var updated: Date
    var sessions: [Session] = []
    var lanes: [Lane] = []
    var providers: [String: Provider] = [:]

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func read(_ url: URL) -> Manifest? {
        (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Manifest.self, from: $0) }
    }

    func write(to url: URL) throws { try Self.encoder.encode(self).write(to: url, options: .atomic) }
}
