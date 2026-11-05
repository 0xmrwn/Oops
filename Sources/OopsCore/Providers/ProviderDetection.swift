import Foundation

/// A server on this Mac answering its preset's loopback endpoint.
public enum LocalServer: Equatable, Sendable { case running([OpenAICompatibleModel]), needsKey }

public extension OpenAICompatibleModels {
    /// `GET <base>/models` for a server on this Mac, given `timeout` seconds: running with its models on 200,
    /// running but wanting a key on 401/403, nil for anything else (refused, timed out, other status, bad JSON).
    /// Loopback only (localhost, 127.0.0.1, ::1); any other host returns nil without a request.
    static func probe(baseURL: URL, timeout: TimeInterval = 0.2, session: URLSession? = nil) async -> LocalServer? {
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(baseURL.host ?? ""), baseURL.scheme == "http" else { return nil }
        let session = session ?? {
            // A system proxy must not intercept loopback, and a probe leaves nothing cached.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.urlCache = nil
            configuration.connectionProxyDictionary = [:]
            return URLSession(configuration: configuration)
        }()
        var request = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 200: return (try? decode(data)).map(LocalServer.running)
        case 401, 403: return .needsKey
        default: return nil
        }
    }
}

/// What onboarding found, read without touching another app's secrets.
public struct ProviderFindings: Equatable, Sendable {
    public enum Row: Hashable, Sendable, Identifiable {
        case claude, chatGPT, local(String)
        public var id: Self { self }
    }

    public var claude: ClaudeCode.Status
    public var chatGPTSignedIn: Bool
    /// Keyed by `ProviderPreset.id` (only local presets); servers that didn't answer are absent.
    public var local: [String: LocalServer]

    public init(claude: ClaudeCode.Status = .notInstalled, chatGPTSignedIn: Bool = false, local: [String: LocalServer] = [:]) {
        self.claude = claude; self.chatGPTSignedIn = chatGPTSignedIn; self.local = local
    }

    /// Can correct right now without any action: Claude signed in, ChatGPT signed in, a local server running.
    public func isUsable(_ row: Row) -> Bool {
        switch row {
        case .claude: if case .signedIn = claude { true } else { false }
        case .chatGPT: chatGPTSignedIn
        case .local(let id): if case .running = local[id] { true } else { false }
        }
    }

    /// Display order, fixed whatever is signed in or running: the accounts first, ChatGPT then Claude, then the local
    /// servers that answered in `ProviderPreset.all` order. Claude and ChatGPT always appear.
    public var rows: [Row] {
        [Row.chatGPT, .claude] + ProviderPreset.all.filter { $0.local && local[$0.id] != nil }.map { Row.local($0.id) }
    }

    /// Preselected: the first usable row; nil when nothing can correct yet.
    public var preferred: Row? { rows.first(where: isUsable) }
}
