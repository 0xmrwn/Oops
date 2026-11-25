import Foundation
import OopsCore

extension ProviderStore {
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

    /// The providers set up and where each stands: usable once a check said so, a problem in the Providers list's
    /// words, or unchecked until one has run.
    var overview: ProviderOverview {
        ProviderOverview(providers: providers, chatGPTOnRecord: chatGPTOnRecord) { provider in
            if let problem = problem(provider.id) { return .problem(problem) }
            return health[provider.id] == .ready ? .usable : .unchecked
        }
    }
}
