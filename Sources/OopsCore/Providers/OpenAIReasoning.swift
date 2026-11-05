import Foundation

/// Request compatibility, not a model catalog: discovery still owns which models are available.
/// Non-reasoning models reject the reasoning option, including `none`; omit it entirely.
enum OpenAIReasoning {
    static func effort(model: String, selected: String?) -> String? {
        // Fine-tuned IDs retain their base model between the first two colons.
        let parts = model.split(separator: ":", omittingEmptySubsequences: false)
        let base = parts.first == "ft" && parts.count > 1 ? String(parts[1]) : model
        let nonReasoning = ["gpt-3.5", "gpt-4", "gpt-4o", "chatgpt-4o"].contains { family in
            base == family || base.hasPrefix(family + "-") || base.hasPrefix(family + ".")
        } || base.range(of: #"^gpt-5(?:\.[0-9]+)?-chat-latest$"#, options: .regularExpression) != nil
        if nonReasoning { return nil }
        // Preserve explicit choices (including `none`); unsupported choices remain API errors.
        // New/unknown families retain the correction default until their capabilities are known.
        return selected ?? ModelSelection.defaultEffort
    }
}
