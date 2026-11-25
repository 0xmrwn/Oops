import SwiftUI

/// A shortcut row's error. When another app seemed to take the keys, "Use anyway" keeps them: the keys may be
/// the person's own keyboard tool's, which looks the same from here.
struct ShortcutErrorLine: View {
    let error: String
    let action: ShortcutSettings.Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                .fixedSize(horizontal: false, vertical: true)
            if let chord = ShortcutInUse.shared.chords[action] {
                Spacer(minLength: 0)
                Button("Use anyway") { NotificationCenter.default.post(name: .shortcutUseAnyway, object: action) }
                    .buttonStyle(.settingsGlass).controlSize(.small)
                    .help("Save \(chord.label) anyway")
            }
        }
    }
}
