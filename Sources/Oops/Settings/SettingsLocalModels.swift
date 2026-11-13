import OopsCore
import SwiftUI

/// Providers → On this Mac: the speech models Oops can download, each with what it costs and its licence before
/// anything is fetched. A few recommended ones are listed; the rest open below them.
struct LocalModelsCard: View {
    let store: ProviderStore
    let local: LocalModels
    @State private var showingAll: Bool

    init(store: ProviderStore, local: LocalModels, showingAll: Bool = false) {
        self.store = store; self.local = local
        _showingAll = State(initialValue: showingAll)
    }

    /// English, then the European languages, then the widest list (Hex's picks for each).
    static let recommended = ["parakeet_unified_en", "parakeet_v3", "nemotron_3_5_asr"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text("On this Mac").font(.headline) } icon: {
                Image(systemName: "laptopcomputer").font(.system(size: 15, weight: .medium)).secondaryText()
            }
            .padding(.bottom, 6)
            ForEach(Array(listed.enumerated()), id: \.element.id) { index, model in
                if index > 0 { Divider() }
                LocalModelRow(model: model, state: local.state(model), local: local) {
                    Task { await store.deleteLocalModel(model, from: local) }
                }
            }
            if !rest.isEmpty || showingAll {
                Divider()
                Button { showingAll.toggle() } label: {
                    HStack {
                        Text(showingAll ? "Show fewer" : "Show all").fontWeight(.medium)
                        Spacer()
                        if !showingAll { Text("\(rest.count)").secondaryText() }
                        Image(systemName: showingAll ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).secondaryText()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .settingsSurface()
        .task { await local.refresh() }
    }

    /// The recommended models, and any other that is installed or on its way, in the catalog's order; all of
    /// them once shown.
    private var listed: [SpeechModel] {
        let top = Self.recommended.compactMap { id in local.models.first { $0.id == id } }
        if showingAll { return top + local.models.filter { !Self.recommended.contains($0.id) } }
        return top + local.models.filter { !Self.recommended.contains($0.id) && local.state($0) != .notInstalled }
    }

    private var rest: [SpeechModel] {
        let ids = Set(listed.map(\.id))
        return local.models.filter { !ids.contains($0.id) }
    }
}

/// A model: name and action, then its languages, size, whether it streams and its licence on one line.
private struct LocalModelRow: View {
    let model: SpeechModel
    let state: LocalModels.State
    let local: LocalModels
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(model.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 8)
                action
            }
            details
            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: state)
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .notInstalled, .failed:
            Button { local.download(model) } label: { Label("Download", systemImage: "arrow.down.circle") }
                .buttonStyle(.settingsGlass)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 90).tint(.primary)
                    .accessibilityLabel("Downloading \(Int(fraction * 100)) percent")
                Text("\(Int(fraction * 100))%").font(.callout.monospacedDigit()).secondaryText()
                Button { local.cancel(model) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.settingsGlass).buttonBorderShape(.circle)
                    .help("Cancel").accessibilityLabel("Cancel download")
            }
        case .verifying:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Verifying").secondaryText() }
        case .installed:
            HStack(spacing: 10) {
                StatusBadge("Installed", ok: true)
                Button(action: delete) { Image(systemName: "trash").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.settingsGlass).buttonBorderShape(.circle)
                    .help("Delete").accessibilityLabel("Delete \(model.name)")
            }
        }
    }

    private var details: some View {
        let facts: [String?] = [Self.languages(model), Self.size(model.artifact.byteCount), model.streams ? "Live" : nil]
        return HStack(spacing: 0) {
            Text(facts.compactMap(\.self).joined(separator: " · ") + " · ")
            Text(Self.license(model.license)).help(model.license.url?.absoluteString ?? "")
        }
        .font(.caption).secondaryText().tint(.primary).lineLimit(1)
    }

    /// One name, a few, or how many.
    static func languages(_ model: SpeechModel) -> String {
        let codes = model.languages.codes
        if codes.count <= 2 { return codes.map(SpeechLanguage.name(of:)).joined(separator: ", ") }
        return "\(codes.count) languages"
    }

    /// A bare name (MIT, Apache-2.0) says it's a licence; linked, underlined, to its text when there is one.
    static func license(_ license: SpeechModelLicense) -> AttributedString {
        guard license.isRecorded else { return AttributedString("License not recorded") }
        var text = AttributedString(license.name.contains("License") ? license.name : license.name + " license")
        if let url = license.url { text.link = url; text.underlineStyle = .single }
        return text
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
