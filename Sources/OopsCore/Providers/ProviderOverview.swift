import Foundation

/// What General says about the providers: the ones the person has set up, and which of those need attention.
public struct ProviderOverview: Equatable, Sendable {
    /// Where a set-up provider stands. Unchecked is neither: nothing has said yet whether it works.
    public enum Standing: Equatable, Sendable { case usable, unchecked, problem(String) }

    public struct Entry: Equatable, Sendable {
        public let provider: Provider
        public let standing: Standing
        public init(provider: Provider, standing: Standing) { self.provider = provider; self.standing = standing }
    }

    /// The set-up providers, in the list's order.
    public let configured: [Entry]
    /// Whether ChatGPT's sign-in has been read yet; until it has, "nothing set up" isn't known.
    public let settled: Bool

    /// `chatGPTOnRecord`: whether a ChatGPT sign-in is on record (signed in, or needing to sign in again); nil
    /// until it has been read.
    public init(providers: [Provider], chatGPTOnRecord: Bool?, standing: (Provider) -> Standing) {
        configured = providers.filter { Self.isConfigured($0.kind, chatGPTOnRecord: chatGPTOnRecord) }
            .map { Entry(provider: $0, standing: standing($0)) }
        settled = chatGPTOnRecord != nil || !configured.isEmpty
    }

    /// ChatGPT is always in the list, as a placeholder until someone signs in; Claude Code and API providers are
    /// there only once added.
    public static func isConfigured(_ kind: Provider.Kind, chatGPTOnRecord: Bool?) -> Bool {
        kind == .chatGPT ? chatGPTOnRecord == true : true
    }

    /// Nothing set up, as far as can be told: the card's case.
    public var noneSetUp: Bool { settled && configured.isEmpty }

    /// What needs attention: the one problem in the Providers list's own words, or how many providers have one.
    public var attention: String? {
        let problems = configured.compactMap { entry -> String? in
            if case .problem(let text) = entry.standing { return text }
            return nil
        }
        return problems.count > 1 ? "\(problems.count) need attention" : problems.first
    }
}

public extension Provider {
    /// The Providers page's sections, in its order: a plan signed in to, an agent installed on this Mac, or an API
    /// reached with a key. Derived from the kind, so nothing stored changes.
    enum Category: CaseIterable, Sendable { case account, agent, api }

    var category: Category {
        switch kind {
        case .chatGPT: .account
        case .claudeCode: .agent
        case .api: .api
        }
    }
}
