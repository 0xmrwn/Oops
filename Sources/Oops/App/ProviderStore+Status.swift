import Foundation

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
}
