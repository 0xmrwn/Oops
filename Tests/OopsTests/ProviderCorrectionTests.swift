import Foundation
@testable import Oops
import OopsCore
import Synchronization
import Testing

@MainActor struct ProviderCorrectionTests {
    @Test(arguments: SetupChange.allCases)
    func `resuming setup checks the attempt before publishing and retains cleanup`(change: SetupChange) async throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        defer { request.cancel() }
        let attempt = CorrectionSession.Attempt(inTryOnly: false, fixture: nil, provider: request)
        let started = Signal(), resume = Signal()
        var generation = attempt.id
        var cleaned = false, published = false
        let operation = Task {
            await started.release(); await resume.wait()
            defer { cleaned = true }
            try attempt.checkCurrent(generation: generation)
            published = true
        }
        await started.wait()
        switch change {
        case .unchanged: break
        case .provider: try fixture.change(.model)
        case .generation: generation = UUID()
        case .cancelledTask: operation.cancel()
        }
        await resume.release()
        if change == .unchanged { try await operation.value }
        else { await #expect(throws: CancellationError.self) { try await operation.value } }
        #expect(cleaned)
        #expect(published == (change == .unchanged))
    }

    enum SetupChange: CaseIterable { case unchanged, provider, generation, cancelledTask }

    @Test func `saving the identical key preserves an active request and its backend`() async throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        let operation = Task { try await request.complete("already clear") }
        await fixture.a.submitted.wait()
        try fixture.store.updateAPI(fixture.primary, name: "Synthetic A", endpoint: "https://a.invalid/v1",
                                    key: "synthetic-key", models: fixture.models)
        await fixture.a.answer.release()
        #expect(try await operation.value == #"{"text":"already clear"}"#)
        #expect(!fixture.a.operationCancelled.withLock { $0 })
        request.finish()
        let next = ProviderCorrection(store: fixture.store)
        #expect(fixture.builds.value == 1)
        next.cancel()
    }

    @Test func `finishing an unused Claude preparation discards its process owner`() async {
        let probe = Probe(), builds = BuildCount()
        let store = ProviderStore(chatGPT: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), preview: true,
                                  makeBackend: { _, _, _ in builds.increment(); return probe })
        store.setShown("claude-code", model: "haiku", true)
        store.select(.init(providerID: "claude-code", modelID: "haiku"))
        let request = ProviderCorrection(store: store)
        await request.preparation?.value
        request.finish()
        let next = ProviderCorrection(store: store)
        #expect(builds.value == 2, "an unused Claude backend must not remain cached")
        next.cancel()
    }

    @Test func `a cancelled attempt cannot reset a newer request on the same Try model`() throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        defer { request.cancel() }
        let model = TestEditorModel()
        let old = CorrectionSession.Attempt(inTryOnly: false, fixture: model, provider: request)
        model.began()
        old.cancelFixture(generation: old.id)
        #expect(model.status == .ready)
        let current = CorrectionSession.Attempt(inTryOnly: false, fixture: model, provider: request)
        model.began()
        old.cancelFixture(generation: current.id)
        #expect(model.status == .working)
        current.cancelFixture(generation: current.id)
        #expect(model.status == .ready)
    }

    @Test func `explicit cancellation reaches a Try fixture distinct from the shared model`() throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        defer { request.cancel() }
        let shared = TestEditorModel(), onboarding = TestEditorModel()
        let attempt = CorrectionSession.Attempt(inTryOnly: false, fixture: onboarding, provider: request)
        onboarding.began()
        #expect(shared.status == .ready)
        attempt.cancelFixture(generation: attempt.id)
        #expect(onboarding.status == .ready)
    }

    @Test func `change during capture cannot submit to a different backend`() async throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        await request.preparation?.value
        fixture.store.select(.init(providerID: fixture.primary, modelID: "b"))
        await fixture.a.answer.release(); await fixture.b.answer.release()
        await #expect(throws: CancellationError.self) { try await request.complete("already clear") }
        #expect(await fixture.a.prepares == 1)
        #expect(await fixture.b.sources.isEmpty)
    }

    @Test(arguments: Change.allCases)
    func `obsolete answers cannot pass to apply or write the clear cache`(change: Change) async throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        let operation = Task { try await request.complete("already clear") }
        await fixture.a.submitted.wait()
        try fixture.change(change)
        await fixture.a.answer.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(fixture.a.operationCancelled.withLock { $0 })
        #expect(throws: CancellationError.self) { try request.rememberClear(app: "synthetic.editor", source: "already clear") }
        let current = ProviderCorrection(store: fixture.store)
        #expect(fixture.builds.value == 2, "changed identity must create a fresh backend")
        #expect(try !current.isClear(app: "synthetic.editor", source: "already clear"))
        current.cancel()
    }

    @Test func `unchanged selection preserves clear caching and successful completion`() async throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        await fixture.a.answer.release()
        #expect(try await request.complete("already clear") == #"{"text":"already clear"}"#)
        try request.rememberClear(app: "synthetic.editor", source: "already clear")
        request.finish()
        let next = ProviderCorrection(store: fixture.store)
        #expect(fixture.builds.value == 1, "unchanged successful presses retain their backend")
        #expect(try next.isClear(app: "synthetic.editor", source: "already clear"))
        #expect(try !next.isClear(app: "another.editor", source: "already clear"))
        #expect(try !next.isClear(app: "synthetic.editor", source: "different draft"))
        next.cancel()
    }

    @Test func `an identity change after completion is rejected at the final apply guard`() async throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        await fixture.a.answer.release()
        _ = try await request.complete("already clear")
        try fixture.change(.model)
        #expect(throws: CancellationError.self) { try request.checkCurrent() }
        #expect(throws: CancellationError.self) { try request.rememberClear(app: "synthetic.editor", source: "already clear") }
        #expect(request.model?.id == "a")
        #expect(request.modelName == "A")
    }

    @Test func `unselected connection edits and unchanged settings preserve the active request`() async throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        let operation = Task { try await request.complete("already clear") }
        await fixture.a.submitted.wait()
        try fixture.store.updateAPI(fixture.secondary, name: "Renamed", endpoint: "https://elsewhere.invalid/v1",
                                    key: "synthetic-new-key", models: fixture.models)
        fixture.store.select(.init(providerID: fixture.primary, modelID: "a"))
        fixture.store.select(effort: "low")
        await fixture.a.answer.release()
        #expect(try await operation.value == #"{"text":"already clear"}"#)
        #expect(!fixture.a.operationCancelled.withLock { $0 })
        try request.rememberClear(app: "synthetic.editor", source: "already clear")
        request.cancel()
    }

    @Test func `cancellation before preparation starts leaves no obsolete warmup`() async throws {
        let fixture = try Fixture()
        let request = ProviderCorrection(store: fixture.store)
        let preparation = request.preparation
        request.cancel()
        await preparation?.value
        #expect(await fixture.a.prepares == 0)
        await #expect(throws: CancellationError.self) { try await request.complete("already clear") }
    }

    @Test func `selection change cancels ongoing preparation while its upkeep can finish`() async throws {
        let fixture = try Fixture()
        await fixture.a.holdPreparation()
        let request = ProviderCorrection(store: fixture.store)
        let preparation = request.preparation
        await fixture.a.preparing.wait()
        try fixture.change(.model)
        #expect(fixture.a.preparationCancelled.withLock { $0 })
        await fixture.a.finishPreparation.release()
        await preparation?.value
        #expect(await fixture.a.preparationFinished)
        #expect(await fixture.a.sources.isEmpty)
    }

    @Test func `a late provider error is cancellation for the obsolete attempt`() async throws {
        let fixture = try Fixture()
        await fixture.a.failAnswer()
        let request = ProviderCorrection(store: fixture.store)
        let operation = Task { try await request.complete("already clear") }
        await fixture.a.submitted.wait()
        try fixture.change(.model)
        await fixture.a.answer.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
    }

    enum Change: CaseIterable { case provider, model, effort, fast, endpoint, key, awayAndBack, hiddenModel }

    @MainActor private final class Fixture {
        let a = Probe(), b = Probe()
        let builds = BuildCount()
        let keys = SyntheticKeys()
        let store: ProviderStore
        let primary: String, secondary: String
        let models: [CatalogModel]
        private let defaults: UserDefaults
        private let suite = "oops-provider-lifetime-" + UUID().uuidString

        init() throws {
            models = try ChatGPTModels.decode(Data(#"{"models":[{"slug":"a","display_name":"A","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}],"service_tiers":[{"id":"priority","name":"Fast"}]}]}"#.utf8))
                .map(CatalogModel.init) + [CatalogModel(id: "b", name: "B")]
            defaults = try #require(UserDefaults(suiteName: suite))
            let a = a, b = b, builds = builds, keys = keys
            var primary: String?
            store = ProviderStore(chatGPT: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), preview: false,
                                  defaults: defaults, writeKey: { keys.write($0, account: $1) }, readKey: { keys.read($0) }, makeBackend: { provider, choice, _ in
                                      builds.increment()
                                      return provider.id == primary && choice.modelID == "a" ? a : b
                                  })
            store.startDraft()
            let first = try #require(store.draft).id
            try store.addDraft(id: first, name: "Synthetic A", endpoint: "https://a.invalid/v1", key: "synthetic-key", models: models)
            store.setShown(first, model: "a", true); store.setShown(first, model: "b", true)
            store.startDraft()
            let second = try #require(store.draft).id
            try store.addDraft(id: second, name: "Synthetic B", endpoint: "https://b.invalid/v1", key: "synthetic-key", models: models)
            store.setShown(second, model: "a", true)
            self.primary = first; secondary = second; primary = first
            store.select(.init(providerID: first, modelID: "a"))
        }

        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        func change(_ change: Change) throws {
            switch change {
            case .provider: store.select(.init(providerID: secondary, modelID: "a"))
            case .model: store.select(.init(providerID: primary, modelID: "b"))
            case .effort: store.select(effort: "medium")
            case .fast: store.setFast(true)
            case .endpoint: try store.updateAPI(primary, name: "Synthetic A", endpoint: "https://changed.invalid/v1", key: nil, models: models)
            case .key: try store.updateAPI(primary, name: "Synthetic A", endpoint: "https://a.invalid/v1", key: "synthetic-new-key", models: models)
            case .awayAndBack:
                store.select(.init(providerID: secondary, modelID: "a"))
                store.select(.init(providerID: primary, modelID: "a"))
            case .hiddenModel: store.setShown(primary, model: "a", false)
            }
        }
    }
}

private actor Signal {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor Probe: CorrectionBackend {
    let submitted = Signal(), answer = Signal(), preparing = Signal(), finishPreparation = Signal()
    nonisolated let operationCancelled = Mutex(false), preparationCancelled = Mutex(false)
    private(set) var prepares = 0
    private(set) var sources: [String] = []
    private(set) var preparationFinished = false
    private var heldPreparation = false, failedAnswer = false
    func holdPreparation() { heldPreparation = true }
    func failAnswer() { failedAnswer = true }
    func prepare() async {
        prepares += 1
        await preparing.release()
        if heldPreparation {
            await withTaskCancellationHandler { await finishPreparation.wait() }
                onCancel: { preparationCancelled.withLock { $0 = true } }
        }
        preparationFinished = true
    }
    func complete(_ text: String) async throws -> String {
        sources.append(text)
        await submitted.release()
        await withTaskCancellationHandler { await answer.wait() }
            onCancel: { operationCancelled.withLock { $0 = true } }
        if failedAnswer { throw CorrectionError.message("Synthetic failure") }
        return #"{"text":"already clear"}"#
    }
}

private final class NoCredentials: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { throw CancellationError() }
    func readCredentials() throws -> ChatGPTCredentials? { throw CancellationError() }
    func writeProfile(_ profile: ChatGPTProfile) throws { throw CancellationError() }
    func writeCredentials(_ credentials: ChatGPTCredentials) throws { throw CancellationError() }
    func deleteCredentials() throws { throw CancellationError() }
}

private final class BuildCount: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

private final class SyntheticKeys: Sendable {
    private let values = Mutex<[String: String]>([:])
    func read(_ account: String) -> String { values.withLock { $0[account] ?? "" } }
    func write(_ key: String, account: String) { values.withLock { $0[account] = key } }
}
