import AppKit
import OopsCore
import SwiftUI

struct ProviderDetail: View {
    let provider: Provider
    let store: ProviderStore
    let preferences: Preferences

    private var saved: Bool { store.provider(provider.id) != nil }

    /// Models appear once there is something to switch.
    private var showsModels: Bool {
        switch provider.kind {
        case .chatGPT: store.health[provider.id] == .ready
        case .claudeCode, .api: saved && store.catalogs[provider.id] != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DrillHeader(title: provider.name, parent: "Providers", back: store.closeDetail) {
                ProviderMark(provider: provider, size: 22)
            }
            switch provider.kind {
            case .chatGPT: ChatGPTProviderSection(preferences: preferences)
            case .claudeCode: ClaudeConnectionCard(store: store)
            case .api: APIProviderForm(provider: provider, store: store, saved: saved)
            }
            if showsModels { ModelsCard(provider: provider, store: store) }
        }
    }
}

/// Same shape as the ChatGPT connection card. Sign-in stays in Claude Code: oops opens Terminal on
/// `claude auth login` and never sees the credentials.
private struct ClaudeConnectionCard: View {
    let store: ProviderStore
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch store.health["claude-code"] ?? .checking {
            case .ready:
                let account = store.claudeAccount
                HStack(spacing: 12) {
                    AccountAvatar(name: account?.organization ?? account?.email ?? "Claude")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account?.organization ?? account?.email ?? "Claude Code").font(.headline).lineLimit(1).truncationMode(.middle)
                        if account?.organization != nil, let email = account?.email {
                            Text(email).font(.callout).secondaryText().lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    StatusBadge("Connected", ok: true)
                }
                Divider()
                HStack(spacing: 12) {
                    Text("Using \(account?.plan ?? "Claude") plan").secondaryText()
                    Spacer()
                    Button { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) } label: {
                        HStack(spacing: 4) {
                            Text("Manage usage")
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(.settingsGlass)
                    .accessibilityLabel("Manage Claude usage (opens in browser)")
                }
                Divider()
                HStack(spacing: 12) {
                    Button { signIn() } label: { Label("Use a different account…", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(.settingsGlass)
                        .help("Opens Terminal to sign Claude Code in to another account.")
                    Spacer()
                    remove
                }
            case .checking:
                HStack { ProgressView().controlSize(.small); Spacer() }
            case .signedOut:
                state("Signed out") { Button("Sign in…") { signIn() }.buttonStyle(.glassProminent).tint(.accentColor) }
            case .notInstalled:
                state("Not installed") {
                    Button("Get Claude Code") { NSWorkspace.shared.open(ClaudeCodeSignIn.install) }
                        .buttonStyle(.glassProminent).tint(.accentColor)
                }
            case .unreachable:
                state("Not reachable") { EmptyView() }
            }
        }
        .settingsSurface()
        .confirmationDialog("Remove Claude Code?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { store.remove("claude-code") }
        } message: {
            Text("Its models leave the picker. Claude Code itself stays signed in.")
        }
    }

    private var remove: some View {
        Button { confirmingRemove = true } label: { Label("Remove", systemImage: "trash") }.buttonStyle(.settingsGlass)
    }

    private func state(_ problem: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Claude Code").font(.headline); Spacer(); StatusBadge(problem, ok: false) }
            if case .unreachable(let message) = store.health["claude-code"] {
                Text(message).font(.callout).secondaryText().textSelection(.enabled)
            }
            Divider()
            HStack(spacing: 12) {
                action()
                Button { store.refreshClaude(force: true) } label: { Label("Check again", systemImage: "arrow.clockwise") }.buttonStyle(.settingsGlass)
                Spacer()
                remove
            }
        }
    }

    private func signIn() {
        if let executable = store.claudeExecutable, ClaudeCodeSignIn.open(executable, finished: { [store] in store.refreshClaude(force: true) }) { return }
        store.refreshClaude(force: true)
    }
}

/// Adds or edits an API provider. Nothing is saved until the endpoint answers with its models, so a
/// provider in the list has always connected at least once.
private struct APIProviderForm: View {
    let provider: Provider
    let store: ProviderStore
    let saved: Bool
    @State private var name = ""
    @State private var endpoint = ""
    @State private var key = ""
    @State private var replacingKey = false
    @State private var busy = false
    @State private var error: String?
    @State private var submission: Task<Void, Never>?
    @State private var confirmingRemove = false

    private var preset: ProviderPreset? { if case .api(let id) = provider.kind { return id.flatMap(ProviderPreset.init(id:)) }; return nil }
    /// Local servers and unknown APIs often take no key; cloud presets always do.
    private var keyOptional: Bool { preset?.local ?? true }
    private var hasSavedKey: Bool { saved && store.hasKey(provider.id) }
    private var typingKey: Bool { !hasSavedKey || replacingKey }
    /// An unnamed API is named after its host.
    private var trimmedName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? URL(string: trimmedEndpoint)?.host ?? "" : typed
    }
    private var trimmedEndpoint: String { endpoint.trimmingCharacters(in: .whitespaces) }
    /// Replace… alone counts: saving it with the field left empty removes the key.
    private var changed: Bool {
        name.trimmingCharacters(in: .whitespaces) != provider.name || trimmedEndpoint != (provider.baseURL ?? "")
            || replacingKey || (typingKey && !key.isEmpty)
    }
    private var ready: Bool {
        guard !busy, let url = URL(string: trimmedEndpoint), url.scheme != nil, url.host != nil else { return false }
        if typingKey && key.isEmpty && !keyOptional && !hasSavedKey { return false }
        return saved ? changed : true
    }
    private var unreachable: String? {
        guard saved, !changed, case .unreachable(let message) = store.health[provider.id] else { return nil }
        return message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !saved { field("Preset") { presetMenu } }
            field("Name") { TextField("Name", text: $name, prompt: Text(URL(string: trimmedEndpoint)?.host ?? "Name")).onSubmit(commit) }
            field("Endpoint") {
                TextField("Endpoint", text: $endpoint, prompt: Text("https://api.example.com/v1")).onSubmit(commit)
            }
            field("API key") {
                if typingKey {
                    SecureField("API key", text: $key, prompt: Text(keyOptional ? "Optional" : "Required")).onSubmit(commit)
                        .help("Stored in your Keychain")
                } else {
                    HStack(spacing: 8) {
                        Label("Saved in Keychain", systemImage: "key").font(.callout)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 6))
                        Button("Replace…") { replacingKey = true }.buttonStyle(.settingsGlass)
                    }
                }
            }
            if let message = error ?? unreachable {
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 12) {
                if saved {
                    Button { confirmingRemove = true } label: { Label("Remove", systemImage: "trash") }.buttonStyle(.settingsGlass).disabled(busy)
                    if unreachable != nil { Button { store.refreshAPI(provider.id, force: true) } label: { Label("Try again", systemImage: "arrow.clockwise") }.buttonStyle(.settingsGlass) }
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else if saved, !changed, store.health[provider.id] == .ready {
                    StatusBadge("Connected", ok: true)
                }
                if !saved { Button("Cancel") { store.closeDetail() }.buttonStyle(.settingsGlass).keyboardShortcut(.cancelAction) }
                Button(saved ? "Save" : "Add", action: commit)
                    .buttonStyle(.glassProminent).tint(.accentColor)
                    .disabled(!ready)
            }
        }
        .textFieldStyle(.roundedBorder)
        .settingsSurface()
        .confirmationDialog("Remove \(provider.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { store.remove(provider.id) }
        } message: {
            Text("Its models leave the picker and its API key is deleted from your Keychain.")
        }
        // Presets start named after themselves; any other API starts blank and takes its host.
        .onAppear { name = saved || preset != nil ? provider.name : ""; endpoint = provider.baseURL ?? "" }
        .onChange(of: [name, endpoint, key]) { error = nil }
        // Leaving the page (Back, Cancel, Remove) drops a check still running.
        .onDisappear { submission?.cancel() }
        // A preset fills the fields in; clearing it leaves them blank for any other API.
        .onChange(of: provider.kind) { name = preset == nil ? "" : provider.name; endpoint = provider.baseURL ?? "" }
    }

    /// The presets: the API services most people use, local servers included. Each fills in only
    /// what stays true for years (name, mark, endpoint); "Custom" is any other OpenAI-compatible API.
    private var presetMenu: some View {
        Menu {
            Button { store.chooseDraftPreset(nil) } label: { Label { Text("Custom") } icon: { MenuIcon.symbol("server.rack") } }
            Divider()
            ForEach(ProviderPreset.all) { option($0) }
        } label: {
            HStack(spacing: 8) {
                ProviderMark(provider: provider, size: 16)
                Text(preset?.name ?? "Custom")
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).secondaryText()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preset, \(preset?.name ?? "Custom")")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func option(_ preset: ProviderPreset) -> some View {
        Button { store.chooseDraftPreset(preset) } label: { Label { Text(preset.name) } icon: { MenuIcon.image(preset.logoAsset, template: true) } }
    }

    /// One row of the form: the label beside its field, so the card stays short enough to fit
    /// the window with the models under it.
    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title).fontWeight(.medium).frame(width: 72, alignment: .leading)
            content().labelsHidden()
        }
    }

    /// Add and Save both list the endpoint's models with the key first; only a working connection is saved.
    private func commit() {
        guard ready else { return }
        busy = true; error = nil
        let name = trimmedName, endpoint = trimmedEndpoint
        // nil keeps the saved key; typed text replaces it; an emptied field removes it. The check and
        // the save both use exactly this.
        let newKey: String? = typingKey ? key : nil
        let id = provider.id
        submission?.cancel()
        submission = Task {
            defer { busy = false }
            do {
                let models = try await store.check(endpoint: endpoint, key: newKey ?? store.savedKey(provider.id))
                try Task.checkCancellation()
                if saved {
                    try store.updateAPI(id, name: name, endpoint: endpoint, key: newKey, models: models)
                } else {
                    try store.addDraft(id: id, name: name, endpoint: endpoint, key: newKey ?? "", models: models)
                }
                // Show what was saved: a blank name became the host.
                self.name = name; self.endpoint = endpoint; key = ""; replacingKey = false
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Switches for the models General's picker shows. A few rows stay inline (Claude's current aliases,
/// ChatGPT's newest, an API's switched-on models); the rest open in a popover, so no catalog makes
/// the page longer than the window.
private struct ModelsCard: View {
    let provider: Provider
    let store: ProviderStore
    @State private var showingMore = false
    /// The popover's list, fixed when it opens.
    @State private var more: [CatalogModel] = []

    private static let inline = 4
    private var catalog: [CatalogModel] { store.catalogs[provider.id] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Same mark as General's Model card.
            Label { Text("Models").font(.headline) } icon: {
                Image(systemName: "cpu").font(.system(size: 15, weight: .medium)).secondaryText()
            }
            .padding(.bottom, 6)
            ForEach(primary) { ModelSwitchRow(model: $0, provider: provider, store: store) }
            if !rest.isEmpty {
                if !primary.isEmpty { Divider() }
                Button { more = rest; showingMore = true } label: {
                    HStack {
                        Text(primary.isEmpty ? "Choose models" : "More models").fontWeight(.medium)
                        Spacer()
                        Text("\(rest.count)").secondaryText()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).secondaryText()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Always above the row: that is where the room is, so every provider opens the same way.
                .popover(isPresented: $showingMore, arrowEdge: .top) {
                    // `more` is fixed when the button is pressed; if the popover is built before that
                    // lands, it lists what is left now rather than nothing.
                    MoreModels(models: more.isEmpty ? rest : more, provider: provider, store: store)
                }
            }
        }
        .settingsSurface()
    }

    /// Inline rows: Claude's aliases, ChatGPT's first few (its catalog lists newest first), and
    /// every switched-on model. A short API catalog is listed whole.
    private var primary: [CatalogModel] {
        let shown = Set(provider.shownModels)
        switch provider.kind {
        case .claudeCode: return catalog.filter { ClaudeCode.isAlias($0.id) || shown.contains($0.id) }
        case .chatGPT:
            let first = Set(catalog.prefix(Self.inline).map(\.id))
            return catalog.filter { first.contains($0.id) || shown.contains($0.id) }
        case .api: return catalog.count <= Self.inline ? catalog : catalog.filter { shown.contains($0.id) }
        }
    }

    private var rest: [CatalogModel] {
        let listed = Set(primary.map(\.id))
        return catalog.filter { !listed.contains($0.id) }
    }
}

private struct ModelSwitchRow: View {
    let model: CatalogModel
    let provider: Provider
    let store: ProviderStore

    var body: some View {
        HStack(spacing: 8) {
            Text(model.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            // The provider's own words, on the same line so the card keeps its height; all of it on hover.
            if let summary = model.summary {
                Text(summary).secondaryText().lineLimit(1).truncationMode(.tail).help(summary)
            }
            Spacer(minLength: 8)
            Toggle(model.name, isOn: Binding(get: { store.provider(provider.id)?.shownModels.contains(model.id) == true },
                                             set: { store.setShown(provider.id, model: model.id, $0) }))
                .settingsSwitch().labelsHidden().controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

/// The models not listed inline. The list is fixed while open, so a model switched on here stays
/// put instead of jumping to the card.
private struct MoreModels: View {
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
