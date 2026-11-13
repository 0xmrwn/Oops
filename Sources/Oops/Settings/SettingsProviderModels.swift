import AppKit
import OopsCore
import SwiftUI

/// One model's switch on a provider's page, and the popover of the models not listed inline.
struct ModelSwitchRow: View {
    let model: CatalogModel
    let provider: Provider
    let store: ProviderStore

    private var shown: Bool { store.provider(provider.id)?.shownModels.contains(model.id) == true }

    var body: some View {
        HStack(spacing: 8) {
            Text(model.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            // The provider's own words, on the same line so the card keeps its height; all of it on hover.
            if let summary = model.summary {
                Text(summary).secondaryText().lineLimit(1).truncationMode(.tail).help(summary)
            }
            Spacer(minLength: 8)
            if DebugFlags.dictation, shown { ModelKindTag(resolution: store.capabilities(.init(providerID: provider.id, modelID: model.id))) }
            Toggle(model.name, isOn: Binding(get: { shown },
                                             set: { store.setShown(provider.id, model: model.id, $0) }))
                .settingsSwitch().labelsHidden().controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

/// The models not listed inline. The list is fixed while open, so a model switched on here stays
/// put instead of jumping to the card.
struct MoreModels: View {
    let models: [CatalogModel]
    let provider: Provider
    let store: ProviderStore
    @State private var filter = ""
    /// ModelSwitchRow: a small switch plus 6 pt above and below.
    private static let rowHeight: CGFloat = 34

    private var matching: [CatalogModel] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? models : models.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if models.count > 8 {
                TextField("Filter", text: $filter, prompt: Text("Filter")).textFieldStyle(.roundedBorder).labelsHidden()
            }
            // An explicit height: a scroll view sized by its content measured zero here and the
            // popover opened empty.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matching) { ModelSwitchRow(model: $0, provider: provider, store: store) }
                }
                .padding(.trailing, 12)
            }
            .scrollIndicators(.visible)
            .frame(height: min(CGFloat(max(matching.count, 1)) * Self.rowHeight, 320))
        }
        .padding(14)
        .frame(width: 360)
        // Opened by a click, the popover would put a ring on its first switch; a filter field
        // keeps focus, since typing is the point.
        .onAppear {
            guard models.count <= 8 else { return }
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }
}

/// What a switched-on model is for, once something has found out: Text (Fix) or Voice (Dictate). A model nothing
/// could identify yet shows no tag.
private struct ModelKindTag: View {
    let resolution: CapabilityResolution

    var body: some View {
        if let capabilities = resolution.capabilities, capabilities.text || capabilities.voice {
            let voice = capabilities.voice && !capabilities.text
            Label(voice ? "Voice" : "Text", systemImage: voice ? "waveform" : "text.alignleft")
                .font(.caption.weight(.medium)).secondaryText()
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.primary.opacity(0.06), in: .capsule)
                .fixedSize()
        }
    }
}
