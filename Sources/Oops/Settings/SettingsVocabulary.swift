import OopsCore
import SwiftUI

/// Dictate → Vocabulary: the user's terms, first the ones that matter most, each with the spellings it is often
/// heard as. A term goes to the speech model as its own mechanism takes it, or corrects the transcript afterwards.
struct VocabularyPage: View {
    var store = VocabularyStore.shared
    @State private var term = ""
    @State private var soundsLike = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Term", text: $term, prompt: Text("Term")).onSubmit(add)
                    TextField("Sounds like", text: $soundsLike, prompt: Text("Sounds like")).onSubmit(add)
                    Button("Add", action: add).buttonStyle(.settingsGlass).controlSize(.large)
                        .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsSurface()
            if !store.entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(store.entries.enumerated()), id: \.element.term) { index, entry in
                        if index > 0 { Divider() }
                        row(entry)
                    }
                }
                .padding(.vertical, -6)
                .settingsSurface()
            }
        }
    }

    private func row(_ entry: VocabularyEntry) -> some View {
        HStack(spacing: 14) {
            Text(entry.term).fontWeight(.semibold)
            if !entry.soundsLike.isEmpty {
                Text(entry.soundsLike.joined(separator: ", ")).secondaryText().lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button { store.remove(entry.term) } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).secondaryText()
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(entry.term)")
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }

    private func add() {
        do {
            try store.add(term, soundsLike: soundsLike)
            term = ""; soundsLike = ""; error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
