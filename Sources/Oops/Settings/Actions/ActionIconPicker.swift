import AppKit
import SwiftUI

/// An action's icon: a search field over a grid of symbols that suit text actions.
struct IconPicker: View {
    @Binding var symbol: String
    let dismiss: () -> Void
    @State private var query = ""

    /// Each symbol with the words that also find it.
    private static let catalog: [(name: String, words: String)] = [
        ("sparkles", "magic improve"), ("wand.and.stars", "magic improve"), ("wand.and.sparkles", "magic clean"), ("globe", "translate language web"),
        ("translate", "language"), ("character.bubble", "translate language"), ("text.bubble", "tone say"), ("bubble.left", "chat reply message"),
        ("bubble.left.and.bubble.right", "chat reply conversation"), ("quote.bubble", "quote say"), ("quote.opening", "quote cite"), ("textformat", "format font"),
        ("textformat.size", "bigger smaller"), ("textformat.abc", "spelling letters"), ("bold", "strong"), ("italic", "emphasis"),
        ("underline", "emphasis"), ("strikethrough", "remove cut"), ("text.alignleft", "paragraph"), ("text.justify", "paragraph block"),
        ("list.bullet", "bullets points"), ("list.number", "steps numbered"), ("list.dash", "outline"), ("checklist", "tasks todo"),
        ("text.badge.checkmark", "proofread check"), ("text.badge.plus", "expand longer add"), ("text.badge.minus", "shorten remove"), ("text.magnifyingglass", "find research"),
        ("magnifyingglass", "search research"), ("doc.text", "document"), ("doc.plaintext", "document plain"), ("doc.richtext", "document format"),
        ("doc.on.doc", "copy duplicate"), ("note.text", "note memo"), ("pencil", "write edit"), ("pencil.line", "write edit"),
        ("pencil.and.outline", "rewrite draft"), ("highlighter", "highlight key"), ("scribble", "draft rough"), ("signature", "sign formal"),
        ("envelope", "mail email"), ("paperplane", "send message"), ("at", "mention email"), ("number", "hashtag count"),
        ("link", "url"), ("tag", "label"), ("bookmark", "save"), ("flag", "important"),
        ("lightbulb", "idea explain"), ("brain", "think reason"), ("brain.head.profile", "think reason"), ("graduationcap", "teach explain academic"),
        ("book", "read story"), ("books.vertical", "library reference"), ("character.book.closed", "dictionary define"), ("text.book.closed", "summary read"),
        ("newspaper", "news headline"), ("megaphone", "announce louder"), ("person", "persona voice"), ("person.2", "audience team"),
        ("hand.thumbsup", "friendly positive"), ("face.smiling", "friendly emoji"), ("heart", "warm kind"), ("star", "favourite best"),
        ("bolt", "fast action"), ("flame", "bold ambitious"), ("scissors", "cut trim shorten"), ("arrow.down.right.and.arrow.up.left", "shorten compress"),
        ("arrow.up.left.and.arrow.down.right", "expand longer"), ("arrow.triangle.2.circlepath", "rewrite again"), ("arrow.uturn.backward", "undo back"), ("shuffle", "rephrase vary"),
        ("repeat", "again"), ("chevron.left.forwardslash.chevron.right", "code"), ("curlybraces", "code json"), ("terminal", "command shell"),
        ("function", "formula"), ("sum", "total formula"), ("chart.bar", "data numbers"), ("tablecells", "table spreadsheet"),
        ("calendar", "date schedule"), ("clock", "time"), ("briefcase", "business formal work"), ("building.2", "company corporate"),
        ("cart", "sales shop"), ("stethoscope", "medical"), ("hammer", "fix build"), ("paintbrush", "style creative"),
        ("eyeglasses", "review proofread"), ("eye", "review look"), ("ear", "listen tone"), ("mic", "speech voice"),
        ("waveform", "voice audio"), ("music.note", "rhyme lyric"), ("theatermasks", "tone role"), ("leaf", "simple plain"),
    ]
    /// Only symbols this macOS has, so no cell is ever blank.
    private static let available = catalog.filter { NSImage(systemSymbolName: $0.name, accessibilityDescription: nil) != nil }

    private var shown: [String] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return Self.available.map(\.name) }
        return Self.available.filter { entry in
            words.allSatisfy { entry.name.contains($0) || entry.words.contains($0) }
        }.map(\.name)
    }

    var body: some View {
        VStack(spacing: 12) {
            GlassSearchField(title: "Search", text: $query)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8), spacing: 4) {
                    ForEach(shown, id: \.self) { name in
                        IconCell(name: name, selected: name == symbol) { symbol = name; dismiss() }
                    }
                }
                .padding(2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: 224)
            .overlay { if shown.isEmpty { Text("No symbol").secondaryText() } }
        }
        .padding(14)
        .frame(width: 8 * 34 + 7 * 4 + 32)
    }
}

private struct IconCell: View {
    let name: String
    let selected: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            Image(systemName: name).font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(.primary.opacity(selected ? 0.16 : hovering ? 0.08 : 0), in: .rect(cornerRadius: 9))
                .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(name.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
