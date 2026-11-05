import Foundation

/// A connection oops corrects through. ChatGPT and Claude Code sign in through their own flows (one of
/// each); API providers are any number of OpenAI-compatible endpoints, each with its own Keychain key.
public struct Provider: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case chatGPT, claudeCode
        /// `preset` picks the name and mark (e.g. "mistral"); nil is any other OpenAI-compatible API.
        case api(preset: String?)
    }
    public let id: String
    public let kind: Kind
    public var name: String
    public var baseURL: String?
    /// Model IDs shown in the General picker (listed there in catalog order).
    public var shownModels: [String]

    public init(id: String, kind: Kind, name: String, baseURL: String? = nil, shownModels: [String] = []) {
        self.id = id; self.kind = kind; self.name = name; self.baseURL = baseURL; self.shownModels = shownModels
    }

    public static func chatGPT() -> Provider { Provider(id: "chatgpt", kind: .chatGPT, name: "ChatGPT") }
    public static func claudeCode() -> Provider { Provider(id: "claude-code", kind: .claudeCode, name: "Claude Code") }
    public static func api(name: String, baseURL: String, preset: String?) -> Provider {
        Provider(id: UUID().uuidString, kind: .api(preset: preset), name: name, baseURL: baseURL)
    }
}

/// One model as the picker sees it, whichever provider listed it.
public struct CatalogModel: Codable, Equatable, Sendable, Identifiable {
    public struct Effort: Codable, Equatable, Sendable { public let id: String, description: String }
    public struct FastTier: Codable, Equatable, Sendable { public let id: String, name: String, description: String }
    public let id: String
    public let name: String
    public let efforts: [Effort]
    public let defaultEffort: String?
    public let fast: FastTier?
    /// The provider's own description of the model (ChatGPT and Claude Code send one).
    public var summary: String? = nil

    public init(id: String, name: String, efforts: [String] = [], defaultEffort: String? = nil, fast: FastTier? = nil,
                descriptions: [String: String] = [:], summary: String? = nil) {
        self.id = id; self.name = name; self.defaultEffort = defaultEffort; self.fast = fast
        self.summary = summary.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.efforts = ModelSelection.supported(efforts).map { Effort(id: $0, description: descriptions[$0] ?? ModelSelection.describe($0)) }
    }

    public init(_ model: ChatGPTModel) {
        let descriptions = Dictionary(model.efforts.map { ($0.id, $0.description) }, uniquingKeysWith: { first, _ in first })
        let tier = model.serviceTiers.first { $0.id != "default" }
        self.init(id: model.slug, name: ModelSelection.modelName(model.displayName), efforts: model.efforts.map(\.id),
                  defaultEffort: model.defaultEffort, fast: tier.map { FastTier(id: $0.id, name: $0.name, description: $0.description) },
                  descriptions: descriptions.filter { !$0.value.isEmpty }, summary: model.description)
    }

    /// API models send no reasoning effort yet, so they show no slider.
    public init(_ model: OpenAICompatibleModel) { self.init(id: model.id, name: model.name) }

    /// Fast mode is not available to `claude -p`, so Claude models never offer it.
    public init(_ model: ClaudeCode.Model) {
        self.init(id: model.value, name: model.name, efforts: model.efforts, summary: model.summary)
    }
}

/// The model General uses, and what each model was last set to.
public struct ModelSelection: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Hashable, Sendable {
        public var providerID: String, modelID: String
        public init(providerID: String, modelID: String) { self.providerID = providerID; self.modelID = modelID }
        var key: String { providerID + "/" + modelID }
    }
    public struct Settings: Codable, Equatable, Sendable {
        public var effort: String?, fast: Bool
        public init(effort: String? = nil, fast: Bool = false) { self.effort = effort; self.fast = fast }
    }

    public var choice: Choice?
    /// Per model, so switching from Luna to Haiku and back keeps each one's effort.
    public var settings: [String: Settings]

    public init(choice: Choice? = nil, settings: [String: Settings] = [:]) { self.choice = choice; self.settings = settings }

    public func settings(for choice: Choice) -> Settings { settings[choice.key] ?? Settings() }
    public mutating func set(_ value: Settings, for choice: Choice) { settings[choice.key] = value }

    /// The benchmarked lightest effort: corrections need speed, not depth.
    public static let defaultEffort = "low"

    // MARK: Efforts

    /// Levels oops offers. `minimal` duplicates `low`; `ultra` delegates to sub-agents, useless here.
    static let order = ["none", "low", "medium", "high", "xhigh", "max"]
    static func supported(_ ids: [String]) -> [String] { order.filter(ids.contains) }

    static func describe(_ id: String) -> String {
        switch id {
        case "none": "No reasoning, fastest responses"
        case "low": "Fast responses with lighter reasoning"
        case "medium": "Balances speed and reasoning depth for everyday tasks"
        case "high": "Greater reasoning depth for complex problems"
        case "xhigh": "Extra high reasoning depth for complex problems"
        default: "Maximum reasoning depth for the hardest problems"
        }
    }

    /// The supported effort closest to `effort` in depth; ties prefer the lighter one. Unknown levels
    /// (e.g. a saved `ultra`) count from the top of the scale.
    public static func nearestEffort(_ effort: String?, in model: CatalogModel) -> String? {
        let supported = model.efforts.map(\.id)
        guard !supported.isEmpty else { return nil }
        guard let effort, !supported.contains(effort) else { return effort ?? supported.first }
        let legacy = ["minimal": "low", "ultra": "max"]
        guard let target = order.firstIndex(of: legacy[effort] ?? effort) else {
            return model.defaultEffort.flatMap { supported.contains($0) ? $0 : nil } ?? supported[0]
        }
        let ranked = supported.compactMap { id in order.firstIndex(of: id).map { (id, abs($0 - target), $0) } }
        return ranked.min { ($0.1, $0.2) < ($1.1, $1.2) }?.0 ?? supported[0]
    }

    /// Back to the correction default: lightest effort, standard speed.
    public static func reset(_ model: CatalogModel) -> Settings {
        Settings(effort: nearestEffort(defaultEffort, in: model), fast: false)
    }

    // MARK: Resolving

    public enum Adjustment: Equatable, Sendable {
        case modelUnavailable(previousName: String)
        case effortUnavailable(previous: String)
        case fastUnavailable
    }

    /// Keeps the choice while its provider shows the model; otherwise picks the first shown model.
    /// A provider whose catalog has not loaded yet (`nil`) keeps everything as saved.
    public static func resolve(_ selection: ModelSelection, providers: [Provider], catalogs: [String: [CatalogModel]])
        -> (selection: ModelSelection, adjustments: [Adjustment]) {
        var result = selection
        var adjustments: [Adjustment] = []
        func shown(_ provider: Provider) -> [CatalogModel]? {
            catalogs[provider.id].map { list in list.filter { provider.shownModels.contains($0.id) } }
        }
        if let choice = selection.choice, let provider = providers.first(where: { $0.id == choice.providerID }),
           shown(provider) == nil { return (selection, []) }
        var model: CatalogModel?
        if let choice = selection.choice, let provider = providers.first(where: { $0.id == choice.providerID }) {
            model = shown(provider)?.first { $0.id == choice.modelID }
        }
        if model == nil {
            guard let fallback = providers.lazy.compactMap({ p in shown(p)?.first.map { (p, $0) } }).first else {
                // Nothing is switched on anywhere: correcting with a hidden model would surprise.
                if let previous = selection.choice {
                    adjustments.append(.modelUnavailable(previousName: modelName(previous.modelID)))
                    result.choice = nil
                }
                return (result, adjustments)
            }
            if let previous = selection.choice {
                adjustments.append(.modelUnavailable(previousName: modelName(previous.modelID)))
            }
            result.choice = Choice(providerID: fallback.0.id, modelID: fallback.1.id)
            model = fallback.1
        }
        guard let model, let choice = result.choice else { return (result, adjustments) }
        var settings = result.settings(for: choice)
        let effort = nearestEffort(settings.effort ?? defaultEffort, in: model)
        if let saved = settings.effort, saved != effort { adjustments.append(.effortUnavailable(previous: saved)) }
        settings.effort = effort
        if settings.fast, model.fast == nil { adjustments.append(.fastUnavailable); settings.fast = false }
        result.set(settings, for: choice)
        return (result, adjustments)
    }

    /// One short sentence per automatic fallback, or nil when nothing changed.
    public static func notice(for adjustments: [Adjustment], model: CatalogModel?, effort: String?) -> String? {
        let current = model?.name ?? "the first available model"
        let sentences = adjustments.map { adjustment -> String in
            switch adjustment {
            case .modelUnavailable(let previous):
                model == nil ? "\(previous) is no longer available. Switch on a model in Providers."
                             : "\(previous) is no longer available. Using \(current)."
            case .effortUnavailable(let previous):
                "\(effortName(previous)) isn’t available for \(current)." + (effort.map { " Using \(effortName($0))." } ?? "")
            case .fastUnavailable: "Fast isn’t available for \(current)."
            }
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    // MARK: Names

    /// Codex-style names: "GPT-6-Luna" → "GPT-6 Luna", "gpt-6.1-sol" → "GPT-6.1 Sol". Names that
    /// already contain spaces are the catalog's own wording and are kept.
    public static func modelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" ") else { return trimmed }
        var parts = trimmed.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return trimmed }
        var words: [String] = []
        if parts.count >= 2, parts[0].caseInsensitiveCompare("gpt") == .orderedSame {
            words.append("GPT-" + parts[1]); parts.removeFirst(2)
        }
        words += parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.joined(separator: " ")
    }

    public static func effortName(_ id: String) -> String {
        switch id {
        case "xhigh": "Extra High"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    // MARK: Defaults and migration

    /// What a provider shows the first time its catalog loads: the preferred models it offers, else
    /// its first model.
    public static func initialShown(_ catalog: [CatalogModel], preferred: [String]) -> [String] {
        let offered = preferred.filter { id in catalog.contains { $0.id == id } }
        return offered.isEmpty ? Array(catalog.prefix(1).map(\.id)) : offered
    }

    public static let preferredChatGPT = ["gpt-6-luna"], preferredClaude = ["haiku"]

    /// A fresh install: ChatGPT with its preferred model, at the default effort.
    public static func initial() -> (providers: [Provider], selection: ModelSelection) {
        var provider = Provider.chatGPT()
        provider.shownModels = preferredChatGPT
        let choice = Choice(providerID: provider.id, modelID: preferredChatGPT[0])
        var selection = ModelSelection(choice: choice)
        selection.set(Settings(effort: defaultEffort, fast: false), for: choice)
        return ([provider], selection)
    }
}
