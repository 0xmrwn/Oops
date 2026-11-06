import AppKit
import Combine
import OopsCore
import SwiftUI

/// Onboarding's Provider step: what this Mac already has, read without touching another app's secrets,
/// and one tiny correction that proves the chosen provider works. Nothing is saved until Continue.
///
/// Without `preferences` (a `--hello-only` run beside a real Oops, which shares its defaults and
/// Keychain) nothing is saved at all, and every correction is simulated.
@MainActor @Observable final class ProviderStep {
    typealias Row = ProviderFindings.Row
    enum Proof: Equatable { case idle, running, passed(String, seconds: Double), failed(String) }
    struct ScanActivity: Equatable {
        let pending: Bool
        let showingAPI: Bool
        let visible: Bool
        let reduceMotion: Bool
    }

    /// The sentence every provider proves itself on, and what a dry run answers.
    static let sample = "Tshi app is vry handy!"
    static let sampleFixed = "This app is very handy!"

    private(set) var findings = ProviderFindings()
    /// The rows on screen: they land one by one once detection is done.
    private(set) var shown: [Row] = []
    private(set) var looking = true
    private var running = false
    private(set) var selected: Row?
    private(set) var proof = Proof.idle
    private(set) var signingIn = false
    /// `claude auth login` is waiting on the browser.
    private(set) var signingInToClaude = false
    var showingAPI = false
    let api: APIProviderSetup
    /// The drop's eyes, in `DashEyes` units: it looks over the rows and turns into a check once one works.
    private(set) var look = CGSize(width: 0, height: 0.3)
    private(set) var lid = 0.0
    private(set) var check = 0.0

    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored let preferences: Preferences?
    @ObservationIgnored private var runtime: ClaudeCodeRuntime?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var proofTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [AnyCancellable] = []
    @ObservationIgnored private let detection: (() async -> ProviderFindings)?
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    /// This step started the ChatGPT sign-in, so a failure message is its to show.
    @ObservationIgnored private var signingInHere = false

    init(preferences: Preferences?, detection: (() async -> ProviderFindings)? = nil,
         pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.preferences = preferences
        self.detection = detection; self.pause = pause; self.now = now
        api = APIProviderSetup(discover: { endpoint, key in
            if let preferences { return try await preferences.providers.check(endpoint: endpoint, key: key) }
            try await Task.sleep(for: .seconds(0.8))
            return [CatalogModel(id: "preview-model", name: "Preview model")]
        }, correct: { configuration in
            if preferences != nil { return try await configuration.backend().correct(Self.sample) }
            try await Task.sleep(for: .seconds(0.8))
            return Self.sampleFixed
        })
        #if DEBUG
        if let state = DebugFlags.onboardingAPI { showingAPI = true; api.seed(state) }
        #endif
    }

    func openAPI(preset: ProviderPreset? = nil) {
        proofTask?.cancel()
        if proof == .running { proof = .idle }
        signingInHere = false
        if preferences?.signingIn == true { preferences?.cancelSignIn() }
        if let preset { api.choose(preset, needsKey: findings.local[preset.id] == .needsKey) }
        showingAPI = true
    }

    func backFromAPI() { api.cancel(); showingAPI = false }
    func discardAPI() { api.clear(); showingAPI = false }

    func commitAPI() -> Bool {
        guard api.passed else { return false }
        guard let store = preferences?.providers else { api.clear(); return true }
        return api.commit(to: store)
    }

    var saves: Bool { preferences != nil }

    func start() {
        guard !running, task == nil else { return }
        #if DEBUG
        // Offscreen snapshots seed their own moment.
        if DebugFlags.setupSnapshots != nil { return }
        #endif
        running = true
        preferences?.chatGPTSignInCompleted.sink { [weak self] in
            self?.signedInToChatGPT()
        }.store(in: &observers)
        preferences?.$signingIn.sink { [weak self] in self?.signingIn = $0 }.store(in: &observers)
        // A sign-in that failed (the browser didn't open, OAuth refused) says why, where proofs do.
        preferences?.$chatGPTMessage.dropFirst().compactMap(\.self).sink { [weak self] message in
            guard let self, self.signingInHere else { return }
            self.signingInHere = false
            self.fail(message)
        }.store(in: &observers)
        // Back from Terminal or the install page: whatever changed shows up without asking.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.recheck() }.store(in: &observers)
        if let preferences, preferences.chatGPTStatus == nil {
            // An existing account belongs in the initial discovery order, not the sign-in event.
            preferences.$chatGPTStatus.compactMap(\.self).first().sink { [weak self] _ in
                self?.beginDiscovery()
            }.store(in: &observers)
            preferences.refreshChatGPT()
        } else {
            beginDiscovery()
        }
    }

    private func beginDiscovery() {
        guard running, task == nil else { return }
        task = Task { [weak self] in await self?.reveal() }
    }

    func stop() {
        running = false
        api.clear()
        task?.cancel(); proofTask?.cancel(); observers = []
        if preferences?.signingIn == true { preferences?.cancelSignIn() }
        if signingInToClaude { ClaudeCodeSignIn.cancel() }
    }

    // MARK: Detecting

    /// The drop scans for a beat however fast detection is, then the rows land under its gaze.
    private func reveal() async {
        let started = now()
        let found = await detect()
        try? await pause(max(.zero, .milliseconds(1200) - started.duration(to: now())))
        guard !Task.isCancelled else { return }
        findings = found
        looking = false
        for (index, row) in found.rows.enumerated() {
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.28)) { shown.append(row); look = Self.look(at: index) }
            try? await pause(.seconds(0.17))
        }
        guard !Task.isCancelled, !showingAPI else { return }
        #if DEBUG
        if let id = DebugFlags.onboardingSetUp, let preset = ProviderPreset(id: id) { return openAPI(preset: preset) }
        #endif
        if let preferred = found.preferred { choose(preferred) }
        else { withAnimation(reduceMotion ? nil : .spring(duration: 0.4)) { look = Self.look(at: 0) } }
    }

    func scanActivity(visible: Bool, reduceMotion: Bool) -> ScanActivity {
        ScanActivity(pending: running && looking, showingAPI: showingAPI, visible: visible, reduceMotion: reduceMotion)
    }

    /// The view owns decoration separately from detection: toggles can cancel and restart only this task.
    func scan(_ activity: ScanActivity) async {
        guard !Task.isCancelled else { return }
        reduceMotion = activity.reduceMotion
        guard activity.pending, running, looking, !activity.showingAPI, !showingAPI else { return }
        guard activity.visible, !reduceMotion else {
            withAnimation(nil) { look = CGSize(width: 0, height: 0.3) }
            return
        }
        var side = 1.0
        do {
            while running, looking, !showingAPI, !reduceMotion {
                try Task.checkCancellation()
                withAnimation(.easeInOut(duration: 0.45)) { look = CGSize(width: 0.85 * side, height: 0.25) }
                side = -side
                try await pause(.seconds(0.55))
            }
        } catch {}
    }

    private func recheck() {
        guard !looking, task != nil else { return }
        Task {
            let found = await detect()
            guard found != findings else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.2)) { findings = found; shown = found.rows }
            if !showingAPI, selected == nil, let preferred = found.preferred { choose(preferred) }
        }
    }

    private func detect() async -> ProviderFindings {
        if let detection { return await detection() }
        #if DEBUG
        if DebugFlags.brandReview {
            return ProviderFindings(claude: .notInstalled, chatGPTSignedIn: true,
                                    local: DebugFlags.onboardingAllProviders ? ["lmstudio": .needsKey, "ollama": .needsKey] : [:])
        }
        let claudeIn = ClaudeCode.Status.signedIn(.init(email: nil, organization: nil, plan: nil))
        switch DebugFlags.onboardingFindings {
        case "fresh": return ProviderFindings()
        case "claude-signed-out": return ProviderFindings(claude: .signedOut)
        case "chatgpt-in": return ProviderFindings(chatGPTSignedIn: true)
        case "claude-in": return ProviderFindings(claude: claudeIn)
        case "both-in": return ProviderFindings(claude: claudeIn, chatGPTSignedIn: true)
        case "local-server": return ProviderFindings(claude: .signedOut, local: ["lmstudio": .running([]), "ollama": .needsKey])
        default: break
        }
        #endif
        let directory = ProviderStore.claudeDirectory
        // The login-shell lookup can take seconds: off the main actor.
        let claude = Task.detached { () -> (ClaudeCodeRuntime?, ClaudeCode.Status) in
            guard let runtime = ClaudeCodeRuntime.locate(directory: directory) else { return (nil, .notInstalled) }
            return (runtime, (try? await runtime.status()) ?? .signedOut)
        }
        var local: [String: LocalServer] = [:]
        await withTaskGroup(of: (String, LocalServer?).self) { group in
            for preset in ProviderPreset.all where preset.local {
                group.addTask { (preset.id, await OpenAICompatibleModels.probe(baseURL: preset.endpoint)) }
            }
            for await (id, server) in group { if let server { local[id] = server } }
        }
        let (runtime, status) = await claude.value
        self.runtime = runtime
        return ProviderFindings(claude: status, chatGPTSignedIn: findings.chatGPTSignedIn || chatGPTSignedIn, local: local)
    }

    private var chatGPTSignedIn: Bool {
        let status: ChatGPTStatus?
        if let preferences {
            status = preferences.chatGPTStatus
        } else {
            status = ChatGPTAuth(store: ChatGPTKeychainStore(), openBrowser: { _ in }).status
        }
        if case .signedIn = status { return true } else { return false }
    }

    /// Eyes on a row: further down the further the row.
    private static func look(at index: Int) -> CGSize { CGSize(width: 0, height: min(1, 0.45 + 0.17 * Double(index))) }

    // MARK: Choosing

    func choose(_ row: Row) {
        guard findings.isUsable(row), !(selected == row && proof != .idle && !isFailed) else { return }
        selected = row
        proofTask?.cancel()
        proof = .running
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2)) { check = 0; lid = 0; look = Self.look(at: shown.firstIndex(of: row) ?? 0) }
        proofTask = Task { [weak self] in await self?.prove(row) }
    }

    private var isFailed: Bool { if case .failed = proof { true } else { false } }

    func signIn(_ row: Row) {
        switch row {
        case .chatGPT:
            if let preferences { signingInHere = true; return preferences.signInWithChatGPT() }
            signingIn = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                signingIn = false
                signedInToChatGPT()
            }
        case .claude:
            if case .notInstalled = findings.claude { NSWorkspace.shared.open(ClaudeCodeSignIn.install) }
            else if let runtime {
                signingInToClaude = ClaudeCodeSignIn.open(runtime.executable) { [weak self] in
                    self?.signingInToClaude = false
                    self?.recheck()
                }
            }
        case .local: break
        }
    }

    private func signedInToChatGPT() {
        signingInHere = false
        withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.2)) { findings.chatGPTSignedIn = true; shown = findings.rows }
        if !showingAPI { choose(.chatGPT) }
    }

    // MARK: Proving

    private func prove(_ row: Row) async {
        guard let preferences else {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            return pass(Self.sampleFixed, seconds: 0.8)
        }
        let backend: any CorrectionBackend
        switch row {
        case .claude:
            guard let runtime else { return fail("Install Claude Code to correct with Claude.") }
            backend = ClaudeCodeBackend(runtime: runtime, model: ModelSelection.preferredClaude[0], effort: nil)
        case .chatGPT:
            backend = ChatGPTBackend(auth: preferences.chatGPT, model: ModelSelection.preferredChatGPT[0])
        case .local(let id):
            guard let preset = ProviderPreset(id: id), let model = localModel(id) else { return fail("The server listed no models.") }
            backend = OpenAICompatibleBackend(configuration: APIConfiguration(baseURL: preset.endpoint, model: model))
        }
        let started = ContinuousClock.now
        do {
            let answer = try await backend.correct(Self.sample)
            let elapsed = started.duration(to: .now)
            guard !Task.isCancelled else { return }
            pass(answer, seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        } catch {
            guard !Task.isCancelled else { return }
            fail(error.localizedDescription)
        }
    }

    private func pass(_ answer: String, seconds: Double) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.3)) { proof = .passed(answer, seconds: seconds); check = 1; look = .zero }
        Sounds.play(.success, after: 0)
    }

    private func fail(_ message: String) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4)) { proof = .failed(message); lid = 0.55 }
        Sounds.play(.failure, after: 0)
    }

    /// The first model a server lists that can write: embedding models can't.
    private func localModel(_ id: String) -> String? {
        guard case .running(let models)? = findings.local[id] else { return nil }
        return (models.first { !$0.id.localizedCaseInsensitiveContains("embed") } ?? models.first)?.id
    }

    #if DEBUG
    /// Sets a moment directly, for `-SetupSnapshots`: detection done, every row landed, the preferred one proven.
    func seed(_ found: ProviderFindings, proof: Proof = .idle, signingIn: Row? = nil) {
        task = Task {}
        findings = found; shown = found.rows; looking = false
        selected = found.preferred; self.proof = found.preferred == nil ? .idle : proof
        self.signingIn = signingIn == .chatGPT; signingInToClaude = signingIn == .claude
        if case .passed = proof { check = 1; look = .zero } else { look = Self.look(at: 0) }
    }
    #endif

    // MARK: Saving

    /// Makes the proven provider the one General corrects with.
    func commit() {
        guard let store = preferences?.providers, case .passed = proof, let selected else { return }
        switch selected {
        case .claude: store.useClaudeCode()
        case .chatGPT: store.useChatGPT()
        case .local(let id):
            guard let preset = ProviderPreset(id: id), let model = localModel(id), case .running(let models)? = findings.local[id] else { return }
            try? store.useLocal(preset, model: model, models: models.map(CatalogModel.init))
        }
    }
}
