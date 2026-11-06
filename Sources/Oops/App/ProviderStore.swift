import AppKit
import Observation
import OopsCore

/// The providers, their catalogs and health, and the model General corrects with. Observation rather
/// than `ObservableObject`: a view re-evaluates only for what it reads, so `Preferences.status`, which
/// changes on every correction, never reaches the Model card or the provider rows.
@Observable @MainActor final class ProviderStore {
    enum Health: Equatable { case ready, checking, signedOut, notInstalled, unreachable(String) }
    /// What a Providers row says: always a state, so a configured provider never looks unknown.
    struct Status: Equatable { let text: String, ok: Bool, busy: Bool }

    private(set) var providers: [Provider] = []
    private(set) var catalogs: [String: [CatalogModel]] = [:]
    private(set) var health: [String: Health] = [:]
    private(set) var selection = ModelSelection()
    /// One sentence when a saved choice had to change (a model disappeared, an effort is unsupported).
    private(set) var notice: String?
    private(set) var claudeAccount: ClaudeCode.Account?
    /// Which provider's detail Providers shows; nil shows the list.
    var openProvider: String?
    /// An API provider being added: shown like a detail page, saved only once Add connects.
    var draft: Provider?
    /// Set by General's picker to ask Settings for the Providers tab. A flag rather than a closure, so
    /// the General page keeps only comparable inputs and is skipped on tab switches.
    var wantsProvidersPage = false

    @ObservationIgnored let preview: Bool
    @ObservationIgnored let chatGPT: ChatGPTAuth
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let writeKey: (String, String) throws -> Void
    @ObservationIgnored let readKey: (String) -> String
    @ObservationIgnored let makeBackend: ((Provider, ModelSelection.Choice, ModelSelection.Settings) throws -> any CorrectionBackend)?
    @ObservationIgnored var lastClear: String?
    @ObservationIgnored var activeCorrection: ProviderCorrection?
    @ObservationIgnored var correctionChanged: () -> Void = {}
    @ObservationIgnored private(set) var correctionRevision = 0
    @ObservationIgnored private var savedCorrectionIdentity: ProviderCorrection.Identity?
    @ObservationIgnored private var correctionKeyRevisions: [String: Int] = [:]
    @ObservationIgnored var claudeRuntime: ClaudeCodeRuntime?
    @ObservationIgnored private var claudeCheckedAt: Date?
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var apiCheckedAt: [String: Date] = [:]
    @ObservationIgnored var cached: (identity: ProviderCorrection.Identity, backend: any CorrectionBackend)?
    @ObservationIgnored private var keyRevision = 0

    static let claudeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("oops/ClaudeCode", isDirectory: true)

    init(chatGPT: ChatGPTAuth, preview: Bool, defaults: UserDefaults = .standard,
         writeKey: @escaping (String, String) throws -> Void = { try KeyStore.write($0, account: $1) },
         readKey: @escaping (String) -> String = { KeyStore.read(account: $0) },
         makeBackend: ((Provider, ModelSelection.Choice, ModelSelection.Settings) throws -> any CorrectionBackend)? = nil) {
        self.defaults = defaults; self.writeKey = writeKey; self.readKey = readKey
        self.makeBackend = makeBackend
        self.chatGPT = chatGPT
        self.preview = preview
        if preview { loadPreview(); return }
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: "providers"), let list = try? decoder.decode([Provider].self, from: data),
           let data = defaults.data(forKey: "modelSelection"), let saved = try? decoder.decode(ModelSelection.self, from: data) {
            providers = list; selection = saved
        } else {
            (providers, selection) = ModelSelection.initial()
        }
        if let data = defaults.data(forKey: "providerCatalogs"), let saved = try? decoder.decode([String: [CatalogModel]].self, from: data) {
            catalogs = saved.filter { id, _ in providers.contains { $0.id == id } }
        }
        for provider in providers where provider.kind != .chatGPT { health[provider.id] = .checking }
        resolve()
    }

    private func save() {
        let identity = correctionIdentity
        if savedCorrectionIdentity != identity {
            savedCorrectionIdentity = identity; correctionRevision += 1; cached = nil
            let active = activeCorrection
            active?.cancel()
            if active != nil { correctionChanged() }
        }
        guard !preview else { return }
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(providers), forKey: "providers")
        defaults.set(try? encoder.encode(selection), forKey: "modelSelection")
        defaults.set(try? encoder.encode(catalogs), forKey: "providerCatalogs")
    }

    var correctionIdentity: ProviderCorrection.Identity {
        let settings = currentSettings
        return .init(choice: selection.choice, kind: currentProvider?.kind, endpoint: currentProvider?.baseURL,
                     settings: settings, tier: settings.fast ? currentModel?.fast?.id : nil,
                     keyRevision: currentProvider.map { correctionKeyRevisions[$0.id, default: 0] } ?? 0)
    }

    // MARK: Reading

    func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }
    var currentProvider: Provider? { selection.choice.flatMap { provider($0.providerID) } }
    var currentModel: CatalogModel? {
        selection.choice.flatMap { choice in catalogs[choice.providerID]?.first { $0.id == choice.modelID } }
    }
    var currentSettings: ModelSelection.Settings { selection.choice.map(selection.settings(for:)) ?? .init() }

    /// The picker's sections: each provider's shown models, in catalog order.
    var pickerGroups: [(provider: Provider, models: [CatalogModel])] {
        providers.compactMap { provider in
            let models = (catalogs[provider.id] ?? []).filter { provider.shownModels.contains($0.id) }
            return models.isEmpty ? nil : (provider, models)
        }
    }

    /// A few words when a provider can't correct right now; nil when it can.
    func problem(_ id: String) -> String? {
        switch health[id] {
        case .signedOut: "Signed out"
        case .notInstalled: "Not installed"
        case .unreachable: "Can’t connect"
        default: nil
        }
    }

    func status(_ id: String) -> Status {
        if let problem = problem(id) { return Status(text: problem, ok: false, busy: false) }
        switch (health[id] ?? .checking, provider(id)?.kind) {
        case (.ready, .api?): return Status(text: "Connected", ok: true, busy: false)
        case (.ready, _): return Status(text: "Signed in", ok: true, busy: false)
        default: return Status(text: "Checking", ok: true, busy: true)
        }
    }

    var claudeExecutable: URL? { claudeRuntime?.executable }

    func hasKey(_ id: String) -> Bool { _ = keyRevision; return !preview && !readKey(id).isEmpty }
    func savedKey(_ id: String) -> String { preview ? "" : readKey(id) }

    /// Back from a detail page, or Cancel on a draft.
    func closeDetail() { openProvider = nil; draft = nil }

    // MARK: Choosing

    func select(_ choice: ModelSelection.Choice) {
        notice = nil
        selection.choice = choice
        resolve()
    }

    func select(effort: String) { update { $0.effort = effort } }
    func setFast(_ on: Bool) { update { $0.fast = on } }
    func resetChoice() { if let model = currentModel { update { $0 = ModelSelection.reset(model) } } }

    private func update(_ change: (inout ModelSelection.Settings) -> Void) {
        guard let choice = selection.choice else { return }
        notice = nil
        var settings = selection.settings(for: choice)
        change(&settings)
        selection.set(settings, for: choice)
        save()
    }

    private func resolve() {
        let (resolved, adjustments) = ModelSelection.resolve(selection, providers: providers, catalogs: catalogs)
        selection = resolved
        if let message = ModelSelection.notice(for: adjustments, model: currentModel, effort: currentSettings.effort) { notice = message }
        save()
    }

    // MARK: Providers

    func addClaudeCode() -> String {
        if provider("claude-code") == nil { providers.append(.claudeCode()); save() }
        refreshClaude(force: true)
        return "claude-code"
    }

    /// Opens the Add page for an API provider, where a preset can fill it in. Nothing is saved yet.
    func startDraft() {
        openProvider = nil
        draft = .api(name: "API provider", baseURL: "", preset: nil)
    }

    /// Picks or clears the draft's preset. The draft keeps its id, so its page stays in place.
    func chooseDraftPreset(_ preset: ProviderPreset?) {
        guard let current = draft else { return }
        let taken = Set(providers.map(\.name))
        let name = preset.map { preset in
            taken.contains(preset.name) ? (2...).lazy.map { "\(preset.name) \($0)" }.first { !taken.contains($0) }! : preset.name
        } ?? "API provider"
        draft = Provider(id: current.id, kind: .api(preset: preset?.id), name: name, baseURL: preset?.endpoint.absoluteString ?? "")
    }

    /// Saves the draft once its connection worked, keeping its id so its page stays in place. `id` is
    /// the draft the check started from: a check that outlived its draft (cancelled, or replaced by
    /// another) saves nothing.
    func addDraft(id: String, name: String, endpoint: String, key: String, models: [CatalogModel]) throws {
        guard var provider = draft, provider.id == id else { return }
        if !key.isEmpty, !preview {
            try writeKey(key, provider.id); keyRevision += 1; correctionKeyRevisions[provider.id, default: 0] += 1
        }
        provider.name = name; provider.baseURL = endpoint
        providers.append(provider)
        catalogs[provider.id] = models
        health[provider.id] = .ready
        apiCheckedAt[provider.id] = Date()
        openProvider = provider.id
        draft = nil
        save()
    }

    /// Applies edits that connected. A nil key keeps the saved one; an empty one removes it. Nothing
    /// is written if the provider was removed while its check ran.
    func updateAPI(_ id: String, name: String, endpoint: String, key: String?, models: [CatalogModel]) throws {
        guard provider(id) != nil else { return }
        if let key, !preview, key != readKey(id) {
            if key.isEmpty { KeyStore.remove(account: id) } else { try writeKey(key, id) }
            keyRevision += 1
            correctionKeyRevisions[id, default: 0] += 1
        }
        edit(id) { $0.name = name; $0.baseURL = endpoint; $0.shownModels.removeAll { model in !models.contains { $0.id == model } } }
        catalogs[id] = models
        health[id] = .ready
        apiCheckedAt[id] = Date()
        resolve()
    }

    func remove(_ id: String) {
        guard let provider = provider(id), provider.kind != .chatGPT else { return }
        if case .api = provider.kind, !preview { KeyStore.remove(account: id) }
        if openProvider == id { openProvider = nil }
        providers.removeAll { $0.id == id }
        catalogs[id] = nil; health[id] = nil
        resolve()
    }

    func setShown(_ id: String, model: String, _ on: Bool) {
        edit(id) { provider in
            provider.shownModels.removeAll { $0 == model }
            if on { provider.shownModels.append(model) }
        }
        resolve()
    }

    private func edit(_ id: String, _ change: (inout Provider) -> Void) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        change(&providers[index])
        save()
    }

    // MARK: Catalogs and health

    func setChatGPT(signedIn: Bool) { health["chatgpt"] = signedIn ? .ready : .signedOut }
    func setChatGPT(models: [ChatGPTModel]) {
        setCatalog("chatgpt", models.map(CatalogModel.init), preferred: ModelSelection.preferredChatGPT)
    }

    /// `preferred` nil leaves every model off: API catalogs carry no defaults, the user picks.
    /// Defaults apply only to a provider's first catalog: an empty selection after that is the user's.
    func setCatalog(_ id: String, _ list: [CatalogModel], preferred: [String]?) {
        guard !list.isEmpty, catalogs[id] != list else { return }
        let first = catalogs[id] == nil
        catalogs[id] = list
        if let preferred, first, provider(id)?.shownModels.isEmpty == true {
            edit(id) { $0.shownModels = ModelSelection.initialShown(list, preferred: preferred) }
        }
        resolve()
    }

    /// Refreshes everything that can be refreshed without bothering anyone; called when Providers or
    /// Settings becomes visible.
    func refresh() {
        refreshClaude()
        for provider in providers { if case .api = provider.kind { refreshAPI(provider.id) } }
    }

    /// Sign-in state, plan and the live model list from the installed CLI, at most once a minute.
    func refreshClaude(force: Bool = false) {
        guard !preview, provider("claude-code") != nil, !loading.contains("claude-code") else { return }
        if !force, let checked = claudeCheckedAt, Date().timeIntervalSince(checked) < 60 { return }
        loading.insert("claude-code")
        if catalogs["claude-code"] == nil { health["claude-code"] = .checking }
        Task {
            defer { loading.remove("claude-code"); claudeCheckedAt = Date() }
            let directory = Self.claudeDirectory
            let runtime: ClaudeCodeRuntime?
            if let known = claudeRuntime { runtime = known } else {
                runtime = await Task.detached { ClaudeCodeRuntime.locate(directory: directory) }.value
            }
            guard let runtime else { health["claude-code"] = .notInstalled; return }
            claudeRuntime = runtime
            do {
                let (status, models) = try await runtime.connect()
                guard provider("claude-code") != nil else { return } // Removed while checking.
                switch status {
                case .signedIn(let account):
                    claudeAccount = account
                    health["claude-code"] = .ready
                    setCatalog("claude-code", models.map(CatalogModel.init), preferred: ModelSelection.preferredClaude)
                case .signedOut: claudeAccount = nil; health["claude-code"] = .signedOut
                case .notInstalled: health["claude-code"] = .notInstalled
                }
            } catch { if provider("claude-code") != nil { health["claude-code"] = .unreachable(error.localizedDescription) } }
        }
    }

    /// Re-lists an API's models, at most once a minute unless forced, so "Connected" is always a result
    /// from this launch.
    func refreshAPI(_ id: String, force: Bool = false) {
        guard !preview, let provider = provider(id), case .api = provider.kind, !loading.contains(id) else { return }
        if !force, let checked = apiCheckedAt[id], Date().timeIntervalSince(checked) < 60 { return }
        loading.insert(id)
        if health[id] != .ready { health[id] = .checking }
        let endpoint = provider.baseURL ?? "", key = readKey(id), revision = keyRevision
        Task {
            defer { loading.remove(id); apiCheckedAt[id] = Date() }
            let result: Result<[CatalogModel], Error>
            do { result = .success(try await check(endpoint: endpoint, key: key)) } catch { result = .failure(error) }
            // A Save or Remove while this ran owns the provider now; this answer is out of date.
            guard self.provider(id)?.baseURL == endpoint, keyRevision == revision else { return }
            switch result {
            case .success(let models): health[id] = .ready; setCatalog(id, models, preferred: nil)
            case .failure(let error): health[id] = .unreachable(error.localizedDescription)
            }
        }
    }

    // MARK: Preview

    /// `SettingsPreviewProviders`: a fixed set of providers for screenshots. No network, Keychain or process.
    private func loadPreview() {
        var chatgpt = Provider.chatGPT(); chatgpt.shownModels = ["gpt-6-luna", "gpt-6.1-sol"]
        var claude = Provider.claudeCode(); claude.shownModels = ["haiku", "sonnet"]
        let mistral = Provider(id: "preview-mistral", kind: .api(preset: "mistral"), name: "Mistral", baseURL: "https://api.mistral.ai/v1",
                               shownModels: ["mistral-small-latest"])
        let groq = Provider(id: "preview-groq", kind: .api(preset: "groq"), name: "Groq", baseURL: "https://api.groq.com/openai/v1")
        let local = Provider(id: "preview-local", kind: .api(preset: "lmstudio"), name: "LM Studio", baseURL: "http://localhost:1234/v1",
                             shownModels: ["qwen-4-8b"])
        providers = [chatgpt, claude, mistral, groq, local]
        let efforts = ["low", "medium", "high", "xhigh", "max"]
        let mistralModels = ["mistral-small-latest", "mistral-medium-latest", "mistral-large-latest", "ministral-8b-latest"].map { CatalogModel(id: $0, name: $0) }
        catalogs = [
            "claude-code": [CatalogModel(id: "haiku", name: "Haiku 5.5", efforts: efforts), CatalogModel(id: "sonnet", name: "Sonnet 5.5", efforts: efforts),
                            CatalogModel(id: "opus", name: "Opus 5.5", efforts: efforts), CatalogModel(id: "fable", name: "Fable 5.1", efforts: efforts),
                            CatalogModel(id: "claude-haiku-4-5-20251001", name: "Haiku 4.5"), CatalogModel(id: "claude-opus-4-8", name: "Opus 4.8", efforts: efforts)],
            "preview-mistral": mistralModels,
            "preview-local": [CatalogModel(id: "qwen-4-8b", name: "qwen-4-8b")]]
        health = ["chatgpt": .ready, "claude-code": .ready, "preview-mistral": .ready, "preview-groq": .unreachable("The provider rejected the API key."),
                  "preview-local": .ready]
        claudeAccount = .init(email: "m@example.com", organization: "Northwind", plan: "Claude Team")
        let choice = ModelSelection.Choice(providerID: "claude-code", modelID: "haiku")
        selection = ModelSelection(choice: choice, settings: [:])
        selection.set(.init(effort: "low"), for: choice)
        // Launch-only: `-SettingsPreviewProvider claude-code` opens that provider's detail.
        openProvider = DebugFlags.provider.flatMap { id in providers.contains { $0.id == id } ? id : nil }
    }
}
