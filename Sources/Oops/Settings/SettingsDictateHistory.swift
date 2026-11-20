import AppKit
import OopsCore
import SwiftUI

/// Dictate's drilled-in pages; its speech model page is `SpeechModelPicker`'s target.
enum DictateDetail: Hashable {
    case vocabulary, history
    static var launchPreview: Self? { DebugFlags.settingsTab == "history" ? .history : nil }
}

/// Dictate's last card: the row that opens History.
struct DictateHistoryCard: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            SettingRow(symbol: DictationHistoryPage.symbol, title: "History") { Chevron() }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -6)
        .settingsSurface()
    }
}

/// Dictate → History: how long dictations are kept, then every one kept, newest first, with search.
struct DictationHistoryPage: View {
    static let symbol = "clock.arrow.circlepath"
    var model = DictationHistoryModel.shared
    @State private var query = ""
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        let all = model.entries(matching: "")
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shown = searching ? model.entries(matching: query) : all
        VStack(alignment: .leading, spacing: 20) {
            SettingRow(symbol: "calendar.badge.clock", title: "Keep for") {
                HStack(spacing: 10) {
                    InfoTip("Keep for", "Dictations stay on this Mac this long, then they’re deleted. Audio is never kept. Off stops saving new ones; "
                        + "the ones already here stay until you clear them or they’re 30 days old.")
                    GlassMenu(title: "Keep for", choices: DictationHistoryRetention.choices,
                              selection: Binding(get: { model.retention }, set: { model.retention = $0 }))
                }
            }
            .padding(.vertical, -6)
            .settingsSurface()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Search", text: $query, prompt: Text("Search")).textFieldStyle(.roundedBorder).labelsHidden()
                        .frame(maxWidth: .infinity)
                    Button { confirming = true } label: { Label("Clear All", systemImage: "trash") }
                        .buttonStyle(.settingsGlass)
                        .disabled(all.isEmpty)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if shown.isEmpty {
                Text(searching ? "No matches" : model.retention.isOff ? "History is off" : "No dictations yet")
                    .secondaryText().frame(maxWidth: .infinity).settingsSurface()
            } else {
                let now = DictationHistory.now()
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { SettingsDivider() }
                        DictationHistoryRow(entry: entry, now: now, insert: model.insert) { delete(entry.id) }
                    }
                }
                .settingsSurface()
            }
        }
        .confirmationDialog("Clear dictation history?", isPresented: $confirming) {
            Button("Clear All", role: .destructive) {
                do { try model.clear(); error = nil } catch { self.error = "Couldn’t clear the history. \(error.localizedDescription)" }
            }
        } message: {
            Text("Every saved dictation is removed. This can’t be undone.")
        }
    }

    private func delete(_ id: Int) {
        do { try model.delete(id); error = nil } catch { self.error = "Couldn’t delete the dictation. \(error.localizedDescription)" }
    }
}

/// One kept dictation: its text, where and when it was said, and Copy, Insert and Delete.
private struct DictationHistoryRow: View {
    let entry: DictationHistoryEntry
    let now: Int
    /// Writes the text at the caret of the app Settings covered; nil while Dictate is off.
    let insert: (@MainActor (String) -> Void)?
    let delete: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text).lineLimit(3).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    if let bundleID = entry.bundleID {
                        Image(nsImage: AppScope.icon(bundleID)).resizable().frame(width: 14, height: 14).accessibilityHidden(true)
                    }
                    Text(details).lineLimit(1).truncationMode(.tail)
                }
                .font(.callout).secondaryText()
                .help(entry.date.formatted(date: .complete, time: .shortened))
            }
            HStack(spacing: 2) {
                icon(copied ? "checkmark" : "doc.on.doc", help: "Copy", label: "Copy dictation") { copy() }
                icon("text.insert", help: "Insert at the caret", label: "Insert dictation at the caret") { insert?(entry.text) }
                    .disabled(insert == nil)
                icon("trash", help: "Delete", label: "Delete dictation", action: delete)
            }
        }
        .padding(.vertical, 10)
    }

    /// The app, the age, the model and the language, each when known.
    private var details: String {
        let language = entry.language.map { DictateModelCard.name($0) }
        return [entry.application, entry.age(now: now), entry.model, language].compactMap(\.self).joined(separator: " · ")
    }

    private func icon(_ symbol: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).secondaryText()
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private func copy() {
        DictationSession.copyToClipboard(entry.text)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            copied = false
        }
    }
}
