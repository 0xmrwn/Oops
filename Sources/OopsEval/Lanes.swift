import Foundation
import OopsCore

/// `fixtures/eval/lanes.json`: every provider the eval runs, its models, effort, pace and limits.
struct LanesConfig: Decodable {
    enum Kind: String, Codable, Sendable { case api, claude, chatgpt, openai }

    /// Per provider, shared by its models.
    struct Pace: Codable, Sendable {
        var rpm: Double?
        var tpm: Double?
        var concurrency: Int?
        /// Requests a day across the provider's models; the rest wait for the next reset.
        var dailyRequests: Int?
        /// Time zone the daily limits reset in (Gemini: America/Los_Angeles); UTC by default.
        var dailyReset: String?
    }

    struct Model: Decodable, Sendable {
        var id: String
        /// Tried in order until the provider accepts one; null sends no effort.
        var effort: [String?]

        enum CodingKeys: String, CodingKey { case id, effort }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            if let list = try? c.decode([String?].self, forKey: .effort) { effort = list.isEmpty ? [nil] : list }
            else { effort = [try c.decodeIfPresent(String.self, forKey: .effort)] }
        }
    }

    struct Provider: Decodable, Sendable {
        var name: String
        var lane: Kind
        /// May name environment variables as `${NAME}` (Cloudflare's account ID).
        var baseUrl: String?
        var keyEnv: String?
        /// Price-table keys and records name the provider by `name`.
        var documented: [String: String]?
        var pace: Pace
        var models: [Model]
    }

    var attempts: Int?
    /// Relative to the config file.
    var prices: String?
    var providers: [Provider]

    static func read(_ url: URL) throws -> LanesConfig {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LanesConfig.self, from: Data(contentsOf: url))
    }

    /// Environment variables the config needs: keys and `${NAME}` in base URLs.
    var environmentNames: Set<String> {
        var names = Set(providers.compactMap(\.keyEnv))
        for provider in providers {
            for match in (provider.baseUrl ?? "").matches(of: /\$\{([A-Z0-9_]+)\}/) { names.insert(String(match.1)) }
        }
        return names
    }
}

/// `KEY=VALUE` lines (comments, `export` and quotes allowed) into this process's environment, only
/// for the names asked for. Values are never printed.
func loadEnvironment(_ url: URL, names: Set<String>) throws {
    for line in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { continue }
        if text.hasPrefix("export ") { text.removeFirst(7) }
        guard let equals = text.firstIndex(of: "=") else { continue }
        let name = text[..<equals].trimmingCharacters(in: .whitespaces)
        var value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first { value = String(value.dropFirst().dropLast()) }
        if names.contains(name) { setenv(name, value, 1) }
    }
}

/// The newest model of a family (`luna`, `haiku`) by the version numbers in its name.
func latest(_ family: String, in names: [String]) -> String? {
    func version(_ name: String) -> [Int] { name.matches(of: /\d+/).compactMap { Int($0.output) } }
    return names.filter { $0.lowercased().contains(family.lowercased()) }
        .max { a, b in version(a).lexicographicallyPrecedes(version(b)) || version(a) == version(b) && a.count > b.count }
}

/// A file-safe model name: `@cf/meta/llama-3.3` → `cf_meta_llama-3.3`.
func fileName(_ model: String) -> String {
    let safe = String(model.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
    return String(safe.drop { $0 == "_" })
}

/// What a provider costs per million tokens at list price, with where each figure came from.
struct PriceTable: Decodable {
    struct Price: Decodable {
        var `in`: Double
        var out: Double
        var cachedIn: Double?
        var source: String
    }

    var checked: String?
    /// Keyed `<provider>/<model>`.
    var models: [String: Price]

    static func read(_ url: URL) -> PriceTable? {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(PriceTable.self, from: $0) }
    }

    func cost(provider: String, model: String, tokens: CallRecord.Tokens?) -> Double? {
        guard let price = models["\(provider)/\(model)"], let tokens, let input = tokens.in, let output = tokens.out else { return nil }
        let cached = tokens.cached ?? 0
        let usd = (Double(input - cached) * price.in + Double(cached) * (price.cachedIn ?? price.in) + Double(output) * price.out) / 1_000_000
        return (usd * 1e9).rounded() / 1e9
    }
}
