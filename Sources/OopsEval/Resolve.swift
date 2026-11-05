import Foundation
import OopsCore

/// A lane ready to run, or the reason it can't.
struct ResolvedLane: Sendable {
    var provider: LanesConfig.Provider
    var configured: String
    /// The model the records name: the API's model ID, Claude's full name, ChatGPT's slug.
    var model: String
    var effort: String?
    var lane: any Lane?
    var skipped: String?
    var file: String { "\(provider.lane.rawValue)--\(fileName(model)).jsonl" }
}

/// Turns the config into lanes: keys and URLs from the environment, `latest:<family>` from each
/// signed-in provider's live catalog (Claude Code's own list, ChatGPT's `/models`).
enum Resolve {
    static func lanes(_ config: LanesConfig, only: Set<String>?) async -> [ResolvedLane] {
        var result: [ResolvedLane] = []
        for provider in config.providers {
            let models = provider.models.filter { only == nil || only!.contains(provider.name) || only!.contains($0.id) }
            guard !models.isEmpty else { continue }
            switch provider.lane {
            case .api: result += models.map { api(provider, $0) }
            case .openai:
                let key = provider.keyEnv.flatMap { ProcessInfo.processInfo.environment[$0] }
                result += models.map { model in
                    var lane = ResolvedLane(provider: provider, configured: model.id, model: model.id, effort: model.effort.first ?? "low")
                    guard let key, !key.isEmpty else { lane.skipped = "missing \(provider.keyEnv ?? "OPENAI_API_KEY")"; return lane }
                    lane.lane = ChatGPTLane(apiKey: key, model: model.id, effort: lane.effort ?? "low")
                    return lane
                }
            case .claude: result += await claude(provider, models)
            case .chatgpt: result += await chatGPT(provider, models)
            }
        }
        return result
    }

    static func api(_ provider: LanesConfig.Provider, _ model: LanesConfig.Model) -> ResolvedLane {
        var lane = ResolvedLane(provider: provider, configured: model.id, model: model.id, effort: model.effort.first ?? nil)
        let environment = ProcessInfo.processInfo.environment
        var base = provider.baseUrl ?? ""
        for match in base.matches(of: /\$\{([A-Z0-9_]+)\}/).reversed() {
            guard let value = environment[String(match.1)], !value.isEmpty else { lane.skipped = "missing \(match.1)"; return lane }
            base.replaceSubrange(match.range, with: value)
        }
        guard let url = URL(string: base) else { lane.skipped = "invalid base_url"; return lane }
        var key = ""
        if let name = provider.keyEnv {
            guard let value = environment[name], !value.isEmpty else { lane.skipped = "missing \(name)"; return lane }
            key = value
        }
        lane.lane = APILane(baseURL: url, model: model.id, key: key, efforts: model.effort)
        return lane
    }

    /// The effort asked for when the model offers it, else its lowest, else none.
    static func effort(_ wanted: [String?], offered: [String]) -> String? {
        if let match = wanted.compactMap(\.self).first(where: offered.contains) { return match }
        return offered.first
    }

    static func claude(_ provider: LanesConfig.Provider, _ models: [LanesConfig.Model]) async -> [ResolvedLane] {
        let skip = { (reason: String) in models.map { ResolvedLane(provider: provider, configured: $0.id, model: $0.id, skipped: reason) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oops-eval-claude")
        guard let runtime = ClaudeCodeRuntime.locate(directory: directory) else { return skip("Claude Code isn't installed") }
        let catalog: [ClaudeCode.Model]
        do {
            let (status, list) = try await runtime.connect()
            guard case .signedIn = status else { return skip("Claude Code is signed out (claude auth login)") }
            catalog = list
        } catch { return skip("Claude Code didn't list its models") }
        return models.map { model in
            var lane = ResolvedLane(provider: provider, configured: model.id, model: model.id)
            let family = model.id.hasPrefix("latest:") ? String(model.id.dropFirst(7)) : nil
            // An alias follows the newest release of its family; a full name stays pinned.
            let found = family.flatMap { family in catalog.first { $0.value == family } ?? latest(family, in: catalog.map(\.value)).flatMap { name in catalog.first { $0.value == name } } }
                ?? catalog.first { $0.value == model.id || $0.resolved == model.id }
            guard let found else { lane.skipped = "not in Claude Code's catalog"; return lane }
            lane.model = found.resolved; lane.effort = effort(model.effort, offered: found.efforts)
            lane.lane = ClaudeLane(runtime: runtime, model: found.value, effort: lane.effort)
            return lane
        }
    }

    static func chatGPT(_ provider: LanesConfig.Provider, _ models: [LanesConfig.Model]) async -> [ResolvedLane] {
        let skip = { (reason: String) in models.map { ResolvedLane(provider: provider, configured: $0.id, model: $0.id, skipped: reason) } }
        // Reads Oops's saved sign-in; macOS asks once before sharing its Keychain item.
        let auth = ChatGPTAuth(openBrowser: { _ in throw CorrectionError.message("Sign in to ChatGPT in Oops first.") })
        let catalog: [ChatGPTModel]
        do { catalog = try await ChatGPTModels.list(using: auth) } catch let error as ChatGPTError { return skip("ChatGPT: \(error.code)") } catch { return skip("ChatGPT didn't list its models") }
        return models.map { model in
            var lane = ResolvedLane(provider: provider, configured: model.id, model: model.id)
            let slug = model.id.hasPrefix("latest:") ? latest(String(model.id.dropFirst(7)), in: catalog.map(\.slug)) : model.id
            guard let found = catalog.first(where: { $0.slug == slug }) else { lane.skipped = "not in ChatGPT's catalog"; return lane }
            lane.model = found.slug
            lane.effort = effort(model.effort, offered: found.efforts.map(\.id)) ?? found.defaultEffort ?? "low"
            lane.lane = ChatGPTLane(auth: auth, model: found.slug, effort: lane.effort ?? "low")
            return lane
        }
    }
}
