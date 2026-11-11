import SwiftUI

// Dictate and Actions as they are planned, every control disabled: nothing here is wired yet. The
// dictation work fills Dictate in, starting with its shortcut; Actions comes with the action library.

/// Dictate's planned settings: the shortcut, the speech model, cleanup, the drop and vocabulary.
struct DictatePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PlaceholderCard(rows: [
                .init(symbol: "keyboard", title: "Shortcut", value: "Record shortcut"),
                .init(symbol: "hand.tap", title: "Mode", value: "Hold or tap"),
            ])
            PlaceholderCard(rows: [
                .init(symbol: "waveform", title: "Speech model", value: "Choose a model"),
                .init(symbol: "globe", title: "Language", value: "Automatic"),
                .init(symbol: "mic", title: "Microphone", value: "System default"),
            ])
            PlaceholderCard(rows: [.init(symbol: "wand.and.sparkles", title: "Clean up", value: "Off")])
            PlaceholderCard(rows: [
                .init(symbol: "circle.grid.3x3", title: "Visualizer", value: "Hex"),
                .init(symbol: "rectangle.bottomhalf.inset.filled", title: "Position", value: "By the text"),
                .init(symbol: "text.bubble", title: "Live words", value: "In the drop"),
            ])
            PlaceholderCard(rows: [.init(symbol: "character.book.closed", title: "Vocabulary", value: nil)])
        }
    }
}

/// Actions' planned settings: its shortcut (none, so off) and the action library.
struct ActionsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PlaceholderCard(rows: [.init(symbol: "keyboard", title: "Shortcut", value: "Record shortcut")])
            PlaceholderCard(rows: [.init(symbol: "square.stack", title: "Library", value: nil)])
        }
    }
}

/// A card of disabled rows, each a setting's name and the value it will start with (or a chevron
/// for a page of its own).
private struct PlaceholderCard: View {
    struct Row: Hashable {
        let symbol: String, title: String, value: String?
    }
    let rows: [Row]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                if index > 0 { Divider() }
                HStack(spacing: 14) {
                    Image(systemName: row.symbol).font(.system(size: 17, weight: .medium)).frame(width: 24)
                        .secondaryText().accessibilityHidden(true)
                    Text(row.title).fontWeight(.semibold)
                    Spacer()
                    if let value = row.value {
                        Text(value).secondaryText()
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText()
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
        .disabled(true)
        .opacity(0.55)
    }
}
