import Foundation

/// Per lane: how many calls gave a usable answer, how fast, and what the pacing cost.
struct LaneReport: Codable {
    var lane: String
    var provider: String
    var model: String
    var state: String
    var calls: Int
    var validRate: Double?
    var p50TotalMs: Int?
    var p95TotalMs: Int?
    var p50TtftMs: Int?
    var p95TtftMs: Int?
    var p50HarnessMs: Int?
    var errors: Int
    var invalid: Int
    var rateLimited: Int
    var queuedS: Double
    var deferred: Int
    var providerPerMinute: Double?
    var verdicts: [String: Int]
    var costUsd: Double?
    var notes: [String]

    static func make(_ directory: URL) throws -> [LaneReport] {
        guard let manifest = Manifest.read(directory.appendingPathComponent("manifest.json")) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.appendingPathComponent("manifest.json").path])
        }
        return try manifest.lanes.map { lane in
            let records = try ResultsFile.existing(directory.appendingPathComponent(lane.file))
            func percentile(_ values: [Int], _ p: Double) -> Int? {
                let sorted = values.sorted()
                return sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
            }
            let answered = records.filter { $0.verdict != "error" }
            let costs = records.compactMap(\.costUsd)
            return LaneReport(lane: lane.lane, provider: lane.provider, model: lane.resolved, state: lane.state, calls: records.count,
                              validRate: records.isEmpty ? nil : Double(records.count { $0.checks.valid }) / Double(records.count),
                              p50TotalMs: percentile(answered.compactMap(\.totalMs), 0.5), p95TotalMs: percentile(answered.compactMap(\.totalMs), 0.95),
                              p50TtftMs: percentile(answered.compactMap(\.ttftMs), 0.5), p95TtftMs: percentile(answered.compactMap(\.ttftMs), 0.95),
                              p50HarnessMs: percentile(answered.compactMap(\.harnessMs), 0.5),
                              errors: records.count { $0.verdict == "error" }, invalid: records.count { $0.verdict == "invalid" },
                              rateLimited: records.reduce(0) { $0 + $1.rateLimited }, queuedS: Double(records.reduce(0) { $0 + $1.queuedMs }) / 1000,
                              deferred: lane.deferred, providerPerMinute: manifest.providers[lane.provider]?.achieved?.perMinute,
                              verdicts: Dictionary(grouping: records, by: \.verdict).mapValues(\.count),
                              costUsd: costs.isEmpty ? nil : costs.reduce(0, +), notes: lane.notes)
        }
    }

    /// A Markdown table, one row per lane.
    static func table(_ reports: [LaneReport]) -> String {
        func seconds(_ ms: Int?) -> String { ms.map { String(format: "%.2f", Double($0) / 1000) } ?? "–" }
        var lines = ["| Lane | Model | Calls | Valid | p50 / p95 total s | p50 / p95 TTFT s | Errors | Invalid | 429s | Queued s | Deferred | Provider req/min |",
                     "|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for r in reports {
            lines.append("| \(r.lane)/\(r.provider) | `\(r.model)` | \(r.calls) | \(r.validRate.map { String(format: "%.0f%%", $0 * 100) } ?? "–") | "
                + "\(seconds(r.p50TotalMs)) / \(seconds(r.p95TotalMs)) | \(seconds(r.p50TtftMs)) / \(seconds(r.p95TtftMs)) | \(r.errors) | \(r.invalid) | "
                + "\(r.rateLimited) | \(String(format: "%.0f", r.queuedS)) | \(r.deferred) | \(r.providerPerMinute.map { String(format: "%.1f", $0) } ?? "–") |")
        }
        let notes = reports.filter { !$0.notes.isEmpty }.map { "- \($0.provider) `\($0.model)`: \($0.notes.joined(separator: "; "))" }
        return (lines + (notes.isEmpty ? [] : [""] + notes)).joined(separator: "\n")
    }
}
