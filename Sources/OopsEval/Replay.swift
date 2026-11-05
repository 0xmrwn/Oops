import Foundation
import OopsCore

/// Logged model answers decoded again with today's rules, next to the strict all-or-nothing check
/// they would have met before reconcile: the same drafts, no model call.
struct Replay: Codable {
    struct Answer: Codable {
        var input: String
        var raw: String
    }

    var answers = 0
    /// Accepted whole by the strict check.
    var strictValid = 0
    /// Every change kept today.
    var full = 0
    /// Some changes refused as unsafe, the rest kept.
    var partial = 0
    /// Nothing safe to keep, or malformed.
    var invalid = 0
    /// Answers with typographic drift set aside.
    var absorbed = 0
    var droppedByRule: [String: Int] = [:]

    init(_ answers: [Answer]) {
        self.answers = answers.count
        for answer in answers {
            if let text = try? CorrectionPolicy.restoredAnswer(answer.raw, original: answer.input),
               (try? CorrectionPolicy.validate(text, original: answer.input)) != nil { strictValid += 1 }
            guard let reconciled = try? CorrectionPolicy.reconcile(answer.raw, original: answer.input) else { invalid += 1; continue }
            if reconciled.dropped.isEmpty { full += 1 } else { partial += 1 }
            if reconciled.absorbed > 0 { absorbed += 1 }
            for change in reconciled.dropped { droppedByRule[change.rule?.rawValue ?? "unknown", default: 0] += 1 }
        }
    }

    /// Attempts in the debug log that reached the model and got an answer back.
    static func answers(in entries: [DebugEntry]) -> [Answer] {
        entries.compactMap { entry in
            guard case .attempt(let attempt) = entry, let input = attempt.source, let raw = attempt.raw else { return nil }
            return Answer(input: input, raw: raw)
        }
    }

    var text: String {
        func share(_ n: Int) -> String { answers == 0 ? "–" : String(format: "%.1f%%", Double(n) / Double(answers) * 100) }
        let rules = droppedByRule.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return """
        \(answers) answers
        before: usable \(share(strictValid)) (\(strictValid))
        now:    usable \(share(full + partial)) (\(full) whole, \(partial) in part) · invalid \(invalid) · drift absorbed in \(absorbed)
        dropped changes: \(rules.isEmpty ? "none" : rules)
        """
    }
}
