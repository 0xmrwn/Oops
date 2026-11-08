import CryptoKit
import Foundation

/// One line of the local debug log: an attempt, or a later label on one. Lines are append-only
/// JSON, so a revert minutes after a correction is its own line pointing back at the attempt, and so
/// is the fix put back after it.
public enum DebugEntry: Codable, Sendable, Equatable {
    case attempt(DebugAttempt)
    case revert(DebugRevert)
    case reapply(DebugRevert)

    public static let version = 1

    private enum CodingKeys: String, CodingKey { case v, kind }
    private enum Kind: String, Codable { case attempt, revert, reapply }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .attempt: self = .attempt(try DebugAttempt(from: decoder))
        case .revert: self = .revert(try DebugRevert(from: decoder))
        case .reapply: self = .reapply(try DebugRevert(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .v)
        switch self {
        case .attempt(let attempt): try container.encode(Kind.attempt, forKey: .kind); try attempt.encode(to: encoder)
        case .revert(let revert): try container.encode(Kind.revert, forKey: .kind); try revert.encode(to: encoder)
        case .reapply(let reapply): try container.encode(Kind.reapply, forKey: .kind); try reapply.encode(to: encoder)
        }
    }
}

/// Everything needed to replay a correction: what was read, sent, returned and applied.
public struct DebugAttempt: Codable, Sendable, Equatable {
    /// `skipped`: answered without a model (nothing but code, links or emoji; unchanged since "Already clear").
    public enum Outcome: String, Codable, Sendable { case fixed, clear, skipped, pending, failed, cancelled }
    public enum Stage: String, Codable, Sendable { case capture, provider, apply }

    public struct App: Codable, Sendable, Equatable {
        public var bundleID: String?
        public var name: String
        public var version: String?
        public init(bundleID: String?, name: String, version: String?) { self.bundleID = bundleID; self.name = name; self.version = version }
    }

    public struct Editor: Codable, Sendable, Equatable {
        public var role: String
        public var subrole: String?
        /// How the text was read; `ax-value` is the only strategy today.
        public var capture: String
        public init(role: String, subrole: String?, capture: String) { self.role = role; self.subrole = subrole; self.capture = capture }
    }

    public struct Model: Codable, Sendable, Equatable {
        /// `chatgpt`, `claude-code` or `api`.
        public var provider: String
        public var providerName: String
        public var id: String
        public var effort: String?
        public var fast: Bool
        public init(provider: String, providerName: String, id: String, effort: String?, fast: Bool) {
            self.provider = provider; self.providerName = providerName; self.id = id; self.effort = effort; self.fast = fast
        }
    }

    /// Milliseconds per stage; nil when the stage didn't run.
    public struct Timings: Codable, Sendable, Equatable {
        public var capture: Int?
        public var provider: Int?
        public var apply: Int?
        public var highlight: Int?
        public init(capture: Int? = nil, provider: Int? = nil, apply: Int? = nil, highlight: Int? = nil) {
            self.capture = capture; self.provider = provider; self.apply = apply; self.highlight = highlight
        }
    }

    public var id: UUID
    public var date: Date
    public var app: App?
    public var editor: Editor?
    /// Whether only a selection was corrected; `source` is then that selection.
    public var selection: Bool?
    /// The full draft as read.
    public var draft: String?
    /// What the model was asked to correct.
    public var source: String?
    public var model: Model?
    public var promptVersion: String?
    public var instructions: String?
    /// The model's answer before decoding.
    public var raw: String?
    /// The decoded correction of `source`, with only its safe changes.
    public var corrected: String?
    /// The answer's changes refused as unsafe, each with the rule it broke.
    public var dropped: [TextChange]?
    /// The answer's changes set aside as typographic drift.
    public var absorbed: Int?
    /// The draft after replacement, as expected and confirmed.
    public var applied: String?
    public var fixes: Int?
    public var outcome: Outcome
    public var failedStage: Stage?
    public var error: String?
    /// The short reason the capsule names (offline, slow, signIn, limit, setup), when there is one.
    public var reason: String?
    public var timings: Timings

    public init(id: UUID = UUID(), date: Date = Date(), outcome: Outcome = .cancelled, timings: Timings = .init()) {
        self.id = id; self.date = date; self.outcome = outcome; self.timings = timings
    }
}

/// A correction taken back (Fix text pressed again, the drop's button or the menu): a strong sign the model got it wrong, unless a later re-apply points at it too.
public struct DebugRevert: Codable, Sendable, Equatable {
    public var attempt: UUID
    public var date: Date
    public init(attempt: UUID, date: Date = Date()) { self.attempt = attempt; self.date = date }
}

/// Monthly JSONL files in one owner-only folder, pruned oldest first past a size cap.
public final class DebugLogStore: @unchecked Sendable {
    public let directory: URL
    public let capacity: Int
    private let queue = DispatchQueue(label: "oops.DebugLog", qos: .utility)

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("oops/Debug")
    }

    public init(directory: URL = DebugLogStore.defaultDirectory, capacity: Int = 200_000_000) {
        self.directory = directory; self.capacity = capacity
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Appends off the caller's thread; the write never blocks a correction.
    public func append(_ entry: DebugEntry) {
        guard var line = try? Self.encoder().encode(entry) else { return }
        line.append(0x0A)
        let date: Date = switch entry { case .attempt(let a): a.date; case .revert(let r), .reapply(let r): r.date }
        queue.async { [self, line] in write(line, date: date) }
    }

    /// Waits for pending appends (tests and the eval tool).
    public func flush() { queue.sync {} }

    public func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("corrections-") && $0.hasSuffix(".jsonl") }.sorted().map { directory.appendingPathComponent($0) }
    }

    public var size: Int {
        files().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    public func deleteAll() throws {
        flush()
        for file in files() { try FileManager.default.removeItem(at: file) }
    }

    /// Every entry, oldest first. Lines that don't decode (a newer version, a torn write) are skipped.
    public func entries() -> [DebugEntry] {
        flush()
        return files().flatMap { Self.entries(in: $0) }
    }

    public static func entries(in file: URL) -> [DebugEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = decoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DebugEntry.self, from: Data($0)) }
    }

    private func write(_ line: Data, date: Date) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: date)
        let file = directory.appendingPathComponent(String(format: "corrections-%04d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0))
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        try? handle.close()
        prune(keeping: file)
    }

    /// Drops whole months, oldest first, until the rest fits; the current file always stays.
    private func prune(keeping current: URL) {
        var files = files().filter { $0 != current }
        var total = size
        while total > capacity, let oldest = files.first {
            total -= (try? oldest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: oldest)
            files.removeFirst()
        }
    }
}

public extension CorrectionPolicy {
    /// Identifies the prompt an answer came from, so evals can compare prompts.
    static var promptVersion: String {
        SHA256.hash(data: Data(instructions.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
