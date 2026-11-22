import Foundation
import Observation
import OopsCore

/// The person's Claude Code skills, asked of Claude Code once while Settings is open and kept until it closes. A
/// failed or slow ask leaves `names` nil: the instruction stays plain text and nothing is shown.
@MainActor @Observable final class SkillCatalog {
    private(set) var names: [String]?
    @ObservationIgnored private var asked = false
    /// Bumped by `reset`, so an answer that arrives after Settings closed is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let fetch: @Sendable (ClaudeCodeRuntime) async -> [String]?

    init(fetch: @escaping @Sendable (ClaudeCodeRuntime) async -> [String]? = { await $0.skillNames() }) {
        self.fetch = fetch
        names = Self.preview
    }

    /// Asks the first time there is a runtime to ask, never again until `reset`, and never on the main thread.
    func loadIfNeeded(runtime: ClaudeCodeRuntime?) {
        guard names == nil, !asked, let runtime else { return }
        asked = true
        let generation = generation, fetch = fetch
        Task { [weak self] in
            let answer = await Task.detached { await fetch(runtime) }.value
            guard let self, self.generation == generation else { return }
            names = answer
        }
    }

    func reset() {
        generation += 1
        asked = false
        names = Self.preview
    }

    /// Debug captures: the names a launch argument lists, so no handshake is made.
    private static var preview: [String]? { DebugFlags.skillNames }
}
