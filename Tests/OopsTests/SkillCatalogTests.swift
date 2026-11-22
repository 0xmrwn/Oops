import Foundation
@testable import Oops
import OopsCore
import Synchronization
import Testing

@MainActor struct SkillCatalogTests {
    private let runtime = ClaudeCodeRuntime(executable: URL(fileURLWithPath: "/nonexistent/claude"), directory: URL(fileURLWithPath: "/tmp"))

    private final class Calls: Sendable {
        private let value = Mutex(0)
        var total: Int { value.withLock { $0 } }
        func add() { value.withLock { $0 += 1 } }
    }

    /// A catalog whose fetch is a counted fake, so no Claude Code runs.
    private func catalog(answer: [String]? = ["review", "summarize"], delay: Duration = .zero) -> (SkillCatalog, Calls) {
        let calls = Calls()
        let catalog = SkillCatalog { _ in
            calls.add()
            try? await Task.sleep(for: delay)
            return answer
        }
        return (catalog, calls)
    }

    private func settle(_ catalog: SkillCatalog, until done: () -> Bool = { true }) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func `asks once however often it is called`() async {
        let (catalog, calls) = catalog()
        for _ in 0..<5 { catalog.loadIfNeeded(runtime: runtime) }
        await settle(catalog) { catalog.names != nil }
        catalog.loadIfNeeded(runtime: runtime)
        await settle(catalog)
        #expect(catalog.names == ["review", "summarize"])
        #expect(calls.total == 1)
    }

    @Test func `does not ask without Claude Code`() async {
        let (catalog, calls) = catalog()
        catalog.loadIfNeeded(runtime: nil)
        await settle(catalog)
        #expect(catalog.names == nil)
        #expect(calls.total == 0)
        // Claude Code turning up later is still asked.
        catalog.loadIfNeeded(runtime: runtime)
        await settle(catalog) { catalog.names != nil }
        #expect(catalog.names != nil)
    }

    @Test func `a failed ask leaves no names and is not repeated`() async {
        let (catalog, calls) = catalog(answer: nil)
        catalog.loadIfNeeded(runtime: runtime)
        await settle(catalog) { calls.total == 1 }
        await settle(catalog)
        catalog.loadIfNeeded(runtime: runtime)
        await settle(catalog)
        #expect(catalog.names == nil)
        #expect(calls.total == 1)
    }

    @Test func `closing Settings forgets the names and the next session asks again`() async {
        let (catalog, calls) = catalog()
        catalog.loadIfNeeded(runtime: runtime)
        await settle(catalog) { catalog.names != nil }
        catalog.reset()
        #expect(catalog.names == nil)
        catalog.loadIfNeeded(runtime: runtime)
        await settle(catalog) { catalog.names != nil }
        #expect(calls.total == 2)
    }

    @Test func `an answer that arrives after Settings closed is dropped`() async {
        let (catalog, _) = catalog(delay: .milliseconds(80))
        catalog.loadIfNeeded(runtime: runtime)
        catalog.reset()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(catalog.names == nil)
    }
}
