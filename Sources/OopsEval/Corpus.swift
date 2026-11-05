import Foundation
import OopsCore

/// One eval case: a draft and what a good correction looks like, as far as the log knows. The fields
/// after `date` come from hand-written sets (`fixtures/eval/README.md`); `export` leaves them out.
struct EvalCase: Codable, Sendable {
    enum Label: String, Codable, Sendable {
        /// Applied and kept: `expected` is the correction.
        case accepted
        /// The model found nothing to fix: `expected` is the input.
        case clear
        /// Applied, then reverted: `rejected` is a bad answer, the right one is unknown.
        case rejected
        /// The model's answer failed validation: `rejected` is that answer, decoded if it decoded.
        case invalid
    }

    var id: String
    var input: String
    var expected: String?
    var rejected: String?
    var label: Label
    var app: String?
    var model: String?
    var date: Date?
    /// Other answers that are also right.
    var alternatives: [String]?
    var origin: String?
    var lang: String?
    var length: String?
    var tags: Tags?
    var split: String?
    var version: String?
    /// A real draft and all synthetic descendants share a split and a sampling unit.
    var family: String?

    struct Tags: Codable, Sendable {
        var errors: [String]?
        var register: String?
        var protected: [String]?
        var clean: Bool?
    }

    /// Nothing to fix: tagged clean, labelled clear, or expected to come back as it is.
    var isClean: Bool { tags?.clean ?? (label == .clear || expected.map { sameText($0, input) } ?? false) }
}

enum Corpus {
    struct Options {
        var includeTry = false
        var includeInvalid = false
        var redact = false
    }

    /// Joins attempts with their reverts, keeps the newest case per input, oldest first. A fix put back
    /// after its revert was kept after all: the last of the two decides.
    static func export(_ entries: [DebugEntry], options: Options) -> [EvalCase] {
        var takenBack: [UUID: Bool] = [:]
        for entry in entries {
            switch entry {
            case .revert(let r): takenBack[r.attempt] = true
            case .reapply(let r): takenBack[r.attempt] = false
            case .attempt: break
            }
        }
        let reverted = Set(takenBack.filter(\.value).keys)
        var byInput: [String: EvalCase] = [:]
        for case .attempt(let attempt) in entries {
            guard let source = attempt.source else { continue }
            if !options.includeTry, attempt.app?.bundleID == "dev.0xmrwn.oops" { continue }
            var item = EvalCase(id: attempt.id.uuidString, input: source, label: .accepted,
                                app: attempt.app?.bundleID ?? attempt.app?.name, model: attempt.model?.id, date: attempt.date)
            item.origin = "real"
            switch attempt.outcome {
            case .fixed:
                guard let corrected = attempt.corrected else { continue }
                if reverted.contains(attempt.id) { item.label = .rejected; item.rejected = corrected }
                else { item.expected = corrected }
            case .clear:
                item.label = .clear; item.expected = source
            // Refused before any paste: by decoding (provider stage) or by the full-draft check (apply
            // stage, with a decoded answer). A failed paste is logged as pending, not here.
            case .failed where options.includeInvalid && (attempt.failedStage == .provider && attempt.raw != nil
                                                            || attempt.failedStage == .apply && attempt.corrected != nil):
                item.label = .invalid; item.rejected = attempt.corrected ?? attempt.raw
            default: continue
            }
            byInput[source] = options.redact ? redacted(item) : item
        }
        return byInput.values.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// Chat-format training lines from cases with a known good answer.
    static func fineTuning(_ cases: [EvalCase], instructions: String) throws -> [Data] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try cases.compactMap { item in
            guard let expected = item.expected, item.label == .accepted || item.label == .clear else { return nil }
            let answer = String(decoding: try encoder.encode(["text": expected]), as: UTF8.self)
            return try encoder.encode(["messages": [["role": "system", "content": instructions],
                                                    ["role": "user", "content": item.input],
                                                    ["role": "assistant", "content": answer]]])
        }
    }

    /// Replaces e-mail addresses and long digit runs with placeholders, one per distinct value and the
    /// same in every field of a case, so its edits survive.
    static func redacted(_ item: EvalCase) -> EvalCase {
        var map: [String: String] = [:]
        func scrub(_ text: String?) -> String? {
            guard var text else { return nil }
            for (pattern, prefix) in [(#"[\w.+-]+@[\w-]+(\.[\w-]+)+"#, "person"), (#"\+?\d[\d \-]{5,}\d"#, "number")] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let ns = text as NSString
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let found = ns.substring(with: match.range)
                    let placeholder = map[found] ?? {
                        let index = String(map.count + 1)
                        let value = prefix == "person" ? "\(prefix)\(index)@example.com"
                            : String(repeating: "0", count: max(0, found.count - index.count)) + index
                        map[found] = value; return value
                    }()
                    text = (text as NSString).replacingCharacters(in: match.range, with: placeholder)
                }
            }
            return text
        }
        var copy = item
        copy.input = scrub(item.input) ?? item.input
        copy.expected = scrub(item.expected); copy.rejected = scrub(item.rejected)
        return copy
    }

    static func read(_ url: URL) throws -> [EvalCase] {
        let decoder = DebugLogStore.decoder()
        return try Data(contentsOf: url).split(separator: 0x0A).map { try decoder.decode(EvalCase.self, from: Data($0)) }
    }

    static func write(_ items: [some Encodable], to url: URL) throws {
        try data(items).write(to: url, options: .atomic)
    }

    static func data(_ items: [some Encodable]) throws -> Data {
        let encoder = DebugLogStore.encoder()
        var data = Data()
        for item in items { data.append(try encoder.encode(item)); data.append(0x0A) }
        return data
    }
}
