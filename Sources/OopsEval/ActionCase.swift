import Foundation
import OopsCore

struct ActionCase: Codable, Sendable {
    var invocation: ActionInvocation

    enum CodingKeys: String, CodingKey { case starter, value, instruction }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if fields.contains(.starter), !fields.contains(.instruction) {
            let name = try fields.decode(String.self, forKey: .starter)
            guard let action = ActionLibrary.starters.actions.first(where: { $0.name == name }) else {
                throw DecodingError.dataCorruptedError(forKey: .starter, in: fields, debugDescription: "Unknown starter: \(name)")
            }
            invocation = .saved(action, value: try fields.decodeIfPresent(String.self, forKey: .value))
        } else if fields.contains(.instruction), !fields.contains(.starter), !fields.contains(.value) {
            invocation = .typed(try fields.decode(String.self, forKey: .instruction))
        } else {
            throw DecodingError.dataCorruptedError(forKey: .instruction, in: fields, debugDescription: "Choose a starter or a custom instruction.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch invocation {
        case .saved(let action, let value):
            try fields.encode(action.name, forKey: .starter)
            try fields.encodeIfPresent(value, forKey: .value)
        case .typed(let text): try fields.encode(text, forKey: .instruction)
        }
    }
}

extension EvalCase {
    var request: ActionRequest {
        if let action { return ActionPrompt.request(for: action.invocation, draft: input) }
        return ActionRequest(instructions: instructions ?? CorrectionPolicy.instructions, input: input)
    }

    var promptVersion: String {
        guard action != nil || instructions != nil else { return CorrectionPolicy.promptVersion }
        return String(Experiment.digest(Data(request.instructions.utf8)).prefix(12))
    }
}

struct ActionChecks: Codable, Sendable {
    enum Target: String, Codable { case en, fr }
    var canary: String?
    var language: Target?
    var shorter: Bool?

    func evaluate(input: String, output: String) -> CallRecord.Checks {
        var result = CallRecord.Checks(valid: true)
        result.canary = canary.map { output.range(of: $0, options: .caseInsensitive) == nil }
        if let language {
            let score = Language.score(output)
            result.language = score.hits >= 3 && (language == .en ? score.value < 0 : score.value > 0)
        }
        if shorter == true { result.shorter = output.count < input.count }
        return result
    }
}

extension CallRecord.Checks {
    var actionVerdict: EvalResult.Verdict {
        [canary, language, shorter].contains(false) ? .failed : .passed
    }
}

struct ActionAnswer {
    let output: String
    let checks: CallRecord.Checks
    var verdict: EvalResult.Verdict { checks.actionVerdict }

    init(raw: String, item: EvalCase) throws {
        output = try ActionPrompt.decode(raw, draft: item.input)
        checks = (item.checks ?? ActionChecks()).evaluate(input: item.input, output: output)
    }
}
