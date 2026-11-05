import Foundation

/// A conservative second reading of a rich editor's copied inline text. Some editors omit
/// non-text embeds (mentions) from plain text while keeping their labels in HTML.
public enum CopiedHTML {
    public static func inlineText(_ html: String) -> String? {
        guard !html.isEmpty, html.utf8.count <= 262_144, !html.contains(where: \.isNewline),
              !html.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let inline: Set = ["span", "a", "b", "strong", "em", "i", "u", "s", "del", "code", "sub", "sup"]
        // Tidy discards some modern attributes. Reject unsupported markup before that repair.
        guard html.range(of: #"\s(?:style|hidden|aria-hidden)\s*(?:=|/?>)"#, options: [.regularExpression, .caseInsensitive]) == nil,
              let tags = try? NSRegularExpression(pattern: #"<\s*(?:/\s*)?([A-Za-z][A-Za-z0-9:-]*)\b"#) else { return nil }
        let source = html as NSString
        guard tags.matches(in: html, range: NSRange(location: 0, length: source.length)).allSatisfy({
            let tag = source.substring(with: $0.range(at: 1)).lowercased()
            return inline.contains(tag) || tag == "meta"
        }) else { return nil }
        let lower = html.lowercased()
        guard !["<!doctype", "<!entity", "<?"].contains(where: lower.contains),
              // The string initializer preserves Unicode; the data initializer's tidy parser assumes Latin-1.
              let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(), let body = root.elements(forName: "body").first else { return nil }
        for node in root.elements(forName: "head").flatMap({ $0.children ?? [] }) where node.kind == .element {
            guard let element = node as? XMLElement,
                  element.localName == "meta" || element.localName == "title" && (element.stringValue ?? "").isEmpty else { return nil }
        }
        var visited = 0
        func read(_ node: XMLNode, depth: Int) -> String? {
            visited += 1
            guard visited <= 4096, depth <= 32 else { return nil }
            if node.kind == .text { return node.stringValue ?? "" }
            if node.kind == .comment { return "" }
            guard let element = node as? XMLElement, inline.contains(element.localName?.lowercased() ?? ""),
                  !(element.attributes ?? []).contains(where: { ["style", "hidden", "aria-hidden"].contains($0.name?.lowercased() ?? "") })
            else { return nil }
            var text = ""
            for child in element.children ?? [] {
                guard let part = read(child, depth: depth + 1) else { return nil }
                text += part
            }
            return text
        }
        var text = ""
        for child in body.children ?? [] {
            guard let part = read(child, depth: 0) else { return nil }
            text += part
        }
        // Tidy can append a document terminator. Never infer paragraph breaks from HTML layout.
        text = text.trimmingCharacters(in: .newlines)
        return text.isEmpty || text.contains(where: \.isNewline) ? nil : text
    }
}
