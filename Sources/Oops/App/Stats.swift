import Foundation
import Observation

/// Lifetime usage, kept on this Mac only: one line per correction with counts and timing, never
/// text. Settings → About shows the totals and charts; the header shows the mistakes fixed.
/// `-SettingsPreviewStats YES` (launch-only) shows a generated month instead and writes nothing.
@MainActor @Observable final class Stats {
    static let shared = Stats()

    struct Event: Codable, Identifiable {
        /// `reapplied`: a reverted fix put back (Fix text pressed again), so that revert no longer counts.
        enum Outcome: String, Codable { case fixed, clear, reverted, reapplied, failed }
        var id: Date { date }
        let date: Date
        let outcome: Outcome
        /// Words in the draft that was checked.
        var words = 0
        /// Changed spans (WordDiff hunks): each is one mistake fixed.
        var fixes = 0
        /// Provider round trip.
        var seconds: Double?
        var model: String?
        /// The app the draft was in, by name.
        var app: String?
    }

    private(set) var events: [Event]
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("oops/Stats/corrections.jsonl")
    private let preview = DebugFlags.sampleStats

    private init() {
        events = preview ? Self.sample() : Self.load(file)
    }

    var corrections: Int { events.count { $0.outcome == .fixed || $0.outcome == .clear } }
    var mistakesFixed: Int { events.reduce(0) { $0 + ($1.outcome == .fixed ? $1.fixes : 0) } }
    var wordsChecked: Int { events.reduce(0) { $0 + ($1.outcome == .fixed || $1.outcome == .clear ? $1.words : 0) } }
    var reverted: Int { max(0, events.count { $0.outcome == .reverted } - events.count { $0.outcome == .reapplied }) }

    func record(_ event: Event) {
        // End-to-end runs with the stub provider never count.
        guard !preview, DebugFlags.stubProvider == nil else { return }
        events.append(event)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    /// Forgets every count: the file first, then what is in memory, so a failed delete changes
    /// nothing and says so.
    func reset() throws {
        if !preview, FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        events = []
    }

    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private static func load(_ file: URL) -> [Event] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Event.self, from: Data($0.utf8)) }
    }

    /// A plausible month of use, the same on every launch.
    private static func sample() -> [Event] {
        var generator = SeededGenerator(seed: 7)
        let models = ["GPT-6 Luna", "Haiku 5.5", "Sonnet 5.5", "qwen3-8b"]
        let apps = ["Slack", "Mail", "Microsoft Teams", "Claude", "Notes", "Linear"]
        let now = Date()
        var events: [Event] = []
        for day in 0..<45 {
            let weekend = Calendar.current.isDateInWeekend(now.addingTimeInterval(Double(-day) * 86_400))
            for _ in 0..<Int.random(in: weekend ? 2...12 : 18...60, using: &generator) {
                let date = now.addingTimeInterval(Double(-day) * 86_400 - Double.random(in: 0...50_000, using: &generator))
                let words = Int.random(in: 4...140, using: &generator)
                let roll = Double.random(in: 0...1, using: &generator)
                let outcome: Event.Outcome = roll < 0.04 ? .failed : roll < 0.07 ? .reverted : roll < 0.27 ? .clear : .fixed
                let model = models[Int.random(in: 0..<models.count, using: &generator)]
                let seconds = (model == "qwen3-8b" ? 0.6 : model == "Haiku 5.5" ? 1.1 : 1.8) + Double.random(in: 0...0.9, using: &generator)
                events.append(Event(date: date, outcome: outcome, words: words,
                                    fixes: outcome == .fixed ? Int.random(in: 1...max(1, words / 14), using: &generator) : 0,
                                    seconds: outcome == .reverted ? nil : seconds, model: model,
                                    app: apps[Int.random(in: 0..<apps.count, using: &generator)]))
            }
        }
        return events.sorted { $0.date < $1.date }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
