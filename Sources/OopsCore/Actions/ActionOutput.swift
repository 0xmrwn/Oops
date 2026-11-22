import Foundation

public enum ActionOutputError: Error, Equatable, Sendable { case empty, malformed }

public extension ActionPrompt {
    /// The replacement in a model's answer. Unlike Fix, an action may rewrite everything, so nothing here judges
    /// length, language or how much changed: only an answer with no usable text fails. The draft's own edge
    /// whitespace is kept, since models trim it.
    static func decode(_ raw: String, draft: String) throws -> String {
        guard let object = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)),
              object.count == 1, let text = object["text"] else { throw ActionOutputError.malformed }
        var answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.hasPrefix("<draft>"), answer.hasSuffix("</draft>") {
            answer = answer.dropFirst("<draft>".count).dropLast("</draft>".count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Models sometimes answer with only a byte-order mark or a zero-width space, which trimming leaves in place.
        let invisible: Set<Unicode.Scalar> = ["\u{FEFF}", "\u{200B}"]
        guard answer.unicodeScalars.contains(where: { !invisible.contains($0) && !$0.properties.isWhitespace }) else {
            throw ActionOutputError.empty
        }
        let leading = draft.prefix(while: \.isWhitespace)
        let trailing = draft[leading.endIndex...].reversed().prefix(while: \.isWhitespace).reversed()
        return leading + answer + String(trailing)
    }
}
