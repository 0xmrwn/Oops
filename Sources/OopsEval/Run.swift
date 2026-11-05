import Foundation
import OopsCore

/// Returns the input unchanged: a baseline, and a way to test the harness without a model.
struct EchoBackend: CorrectionBackend {
    func complete(_ text: String) async throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
    }
}

struct EvalResult: Codable {
    enum Verdict: String, Codable {
        case exact
        /// Changed text that needed no change.
        case overcorrected
        /// Left unchanged text that needed a change.
        case missed
        /// Changed, but not into the expected text.
        case different
        /// Returned the answer the user reverted.
        case repeatedRejection
        /// No expected answer to compare with.
        case unscored
        case invalid
        case error
    }

    var id: String
    var label: EvalCase.Label
    var verdict: Verdict
    /// The case's draft and the model's answer before decoding, so `replay` can decode it again.
    var input: String?
    var raw: String?
    var output: String?
    var error: String?
    /// Character edit distance to the expected text, divided by its length.
    var distance: Double?
    /// The answer's changes refused as unsafe; the rest were kept.
    var dropped: Int?
    var milliseconds: Int
}

enum Runner {
    static func run(_ cases: [EvalCase], backend: any CorrectionBackend, jobs: Int,
                    progress: @escaping @Sendable (Int) -> Void) async -> [EvalResult] {
        await withTaskGroup(of: (Int, EvalResult).self) { group in
            var results = [EvalResult?](repeating: nil, count: cases.count), next = 0, done = 0
            func start() {
                guard next < cases.count else { return }
                let index = next, item = cases[index]; next += 1
                group.addTask { (index, await evaluate(item, backend: backend)) }
            }
            for _ in 0..<max(jobs, 1) { start() }
            for await (index, result) in group {
                results[index] = result; done += 1; progress(done); start()
            }
            return results.compactMap(\.self)
        }
    }

    static func evaluate(_ item: EvalCase, backend: any CorrectionBackend) async -> EvalResult {
        let started = ContinuousClock.now
        var result = EvalResult(id: item.id, label: item.label, verdict: .error, input: item.input, milliseconds: 0)
        do {
            let raw = try await backend.complete(item.input)
            result.raw = raw
            do {
                let reconciled = try CorrectionPolicy.reconcile(raw, original: item.input)
                let output = reconciled.text
                result.output = output
                if !reconciled.dropped.isEmpty { result.dropped = reconciled.dropped.count }
                result.verdict = verdict(output, for: item)
                if let expected = item.expected { result.distance = distance(output, expected) }
            } catch {
                result.verdict = .invalid; result.output = raw; result.error = error.localizedDescription
            }
        } catch {
            result.error = error.localizedDescription
        }
        result.milliseconds = Int((started.duration(to: .now) / .milliseconds(1)).rounded())
        return result
    }

    static func verdict(_ output: String, for item: EvalCase) -> EvalResult.Verdict {
        if let expected = item.expected {
            if sameText(output, expected) || (item.alternatives ?? []).contains(where: { sameText(output, $0) }) { return .exact }
            if sameText(expected, item.input) { return .overcorrected }
            return sameText(output, item.input) ? .missed : .different
        }
        if let rejected = item.rejected, sameText(output, rejected) { return .repeatedRejection }
        return .unscored
    }

    /// Levenshtein over UTF-16 units, normalised by the expected length; nil past 4,000 units.
    static func distance(_ a: String, _ b: String) -> Double? {
        let x = Array(a.utf16), y = Array(b.utf16)
        guard x.count <= 4_000, y.count <= 4_000 else { return nil }
        if y.isEmpty { return x.isEmpty ? 0 : 1 }
        if x.isEmpty { return 1 }
        var previous = Array(0...y.count), current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return Double(previous[y.count]) / Double(y.count)
    }
}

struct Summary: Codable {
    var model: String
    var promptVersion: String
    var cases: Int
    var verdicts: [String: Int]
    /// Exact answers among cases with an expected text.
    var exactRate: Double?
    var overcorrectionRate: Double?
    var missRate: Double?
    var invalidRate: Double
    /// Answers kept only in part: some of their changes were refused as unsafe.
    var partialRate: Double
    var errorRate: Double
    var meanDistance: Double?
    var p50Milliseconds: Int?
    var p90Milliseconds: Int?

    init(_ results: [EvalResult], cases: [EvalCase], model: String) {
        self.model = model
        promptVersion = CorrectionPolicy.promptVersion
        self.cases = results.count
        verdicts = Dictionary(grouping: results, by: \.verdict.rawValue).mapValues(\.count)
        let byID = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func rate(_ hits: Int, _ total: Int) -> Double? { total == 0 ? nil : Double(hits) / Double(total) }
        let scored = results.filter { byID[$0.id]?.expected != nil && $0.verdict != .error && $0.verdict != .invalid }
        let unchanged = scored.filter { byID[$0.id].map { sameText($0.expected ?? "", $0.input) } ?? false }
        let changed = scored.filter { byID[$0.id].map { !sameText($0.expected ?? "", $0.input) } ?? false }
        exactRate = rate(scored.count { $0.verdict == .exact }, scored.count)
        overcorrectionRate = rate(unchanged.count { $0.verdict == .overcorrected }, unchanged.count)
        missRate = rate(changed.count { $0.verdict == .missed }, changed.count)
        invalidRate = rate(results.count { $0.verdict == .invalid }, results.count) ?? 0
        partialRate = rate(results.count { $0.dropped != nil }, results.count) ?? 0
        errorRate = rate(results.count { $0.verdict == .error }, results.count) ?? 0
        let distances = scored.compactMap(\.distance)
        meanDistance = distances.isEmpty ? nil : distances.reduce(0, +) / Double(distances.count)
        let times = results.filter { $0.verdict != .error }.map(\.milliseconds).sorted()
        func percentile(_ p: Double) -> Int? { times.isEmpty ? nil : times[min(times.count - 1, Int(Double(times.count) * p))] }
        p50Milliseconds = percentile(0.5); p90Milliseconds = percentile(0.9)
    }

    var text: String {
        func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }
        let counts = verdicts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return """
        model \(model) · prompt \(promptVersion) · \(cases) cases
        exact \(percent(exactRate)) · overcorrected \(percent(overcorrectionRate)) · missed \(percent(missRate)) · invalid \(percent(invalidRate)) · partial \(percent(partialRate)) · errors \(percent(errorRate))
        mean distance \(meanDistance.map { String(format: "%.3f", $0) } ?? "–") · p50 \(p50Milliseconds.map { "\($0) ms" } ?? "–") · p90 \(p90Milliseconds.map { "\($0) ms" } ?? "–")
        \(counts)
        """
    }
}
