import Foundation
import Observation
import OopsCore

/// An onboarding-owned transaction. Discovery and proof never alter Settings or the Keychain.
@MainActor @Observable final class APIProviderSetup {
    typealias Discover = (String, String) async throws -> [CatalogModel]
    typealias Correct = (APIConfiguration) async throws -> String
    enum Phase: Equatable { case credentials, discovering, models, proving, passed(String, Double) }

    private(set) var preset: ProviderPreset?
    private(set) var endpoint = ""
    private(set) var key = ""
    private var serverNeedsKey = false
    private(set) var model = ""
    var enteringKey = false
    private(set) var models: [CatalogModel] = []
    private(set) var phase = Phase.credentials
    private(set) var error: String?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let discover: Discover
    @ObservationIgnored private let correct: Correct

    init(discover: @escaping Discover, correct: @escaping Correct) {
        self.discover = discover; self.correct = correct
    }

    var address: String { endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
    var name: String { preset?.name ?? URL(string: address)?.host ?? "API provider" }
    var keyOptional: Bool { !serverNeedsKey && (preset?.local ?? true) }
    var busy: Bool { phase == .discovering || phase == .proving }
    var connected: Bool { !models.isEmpty }
    var passed: Bool { if case .passed = phase { true } else { false } }
    var canConnect: Bool { !busy && !address.isEmpty && (keyOptional || !key.isEmpty) }
    var canProve: Bool { !busy && models.contains { $0.id == model } }

    func choose(_ preset: ProviderPreset?, needsKey: Bool = false) {
        edit(); self.preset = preset; serverNeedsKey = needsKey; endpoint = preset?.endpoint.absoluteString ?? ""; key = ""
    }

    func changeEndpoint(_ value: String) {
        guard endpoint != value else { return }
        edit(); serverNeedsKey = false; endpoint = value
    }

    func changeKey(_ value: String) {
        guard key != value else { return }
        edit(); key = value
    }

    /// Any connection edit invalidates the catalog and proof; a model edit invalidates only proof.
    func edit() { cancel(); models = []; model = ""; phase = .credentials; error = nil }
    func chooseModel(_ id: String) { guard model != id else { return }; cancel(); model = id; phase = .models; error = nil }
    func clear() { enteringKey = false; edit(); preset = nil; serverNeedsKey = false; endpoint = ""; key = "" }

    /// Back retains entered values and completed results, while dropping any late answer.
    func cancel() {
        revision += 1; operation?.cancel(); operation = nil
        if phase == .discovering { phase = .credentials }
        if phase == .proving { phase = .models }
    }

    func connect() {
        guard canConnect else { return }
        edit()
        guard let url = URL(string: address), APIConfiguration.isSafe(url), url.host?.isEmpty == false else {
            error = "Use an HTTPS endpoint, or HTTP on localhost, including /v1 if required."; return
        }
        phase = .discovering
        let revision = revision, endpoint = address, key = key
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await discover(endpoint, key)
                guard !Task.isCancelled, self.revision == revision else { return }
                guard !list.isEmpty else { throw CorrectionError.message("The provider listed no models. Load a model, then try again.") }
                models = list
                model = (list.first { !$0.id.localizedCaseInsensitiveContains("embed") } ?? list[0]).id
                phase = .models
            } catch {
                guard !Task.isCancelled, self.revision == revision else { return }
                phase = .credentials; self.error = error.localizedDescription
            }
        }
    }

    func prove() {
        guard canProve, let url = URL(string: address) else { return }
        cancel(); phase = .proving; error = nil
        let revision = revision, started = ContinuousClock.now
        let configuration = APIConfiguration(baseURL: url, model: model, apiKey: key)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await correct(configuration)
                guard !Task.isCancelled, self.revision == revision else { return }
                let elapsed = started.duration(to: .now).components
                phase = .passed(answer, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            } catch {
                guard !Task.isCancelled, self.revision == revision else { return }
                phase = .models; self.error = error.localizedDescription
            }
        }
    }

    /// The store owns the durable write, with the key first so a Keychain failure saves no provider.
    func commit(to store: ProviderStore) -> Bool {
        guard passed else { return false }
        do {
            try store.addOnboardingAPI(preset: preset, endpoint: address, key: key, models: models, model: model)
            clear(); return true
        } catch { self.error = error.localizedDescription; return false }
    }

    #if DEBUG
    func seed(_ state: String) {
        choose(ProviderPreset(id: state == "local" ? "lmstudio" : "mistral"))
        if state != "local" { key = "preview-key" }
        if ["models", "proving", "passed", "failure"].contains(state) {
            models = ["mistral-small-latest", "mistral-medium-latest", "mistral-large-latest"].map { CatalogModel(id: $0, name: $0) }
            model = models[0].id; phase = .models
        }
        if state == "discovering" { phase = .discovering }
        if state == "proving" { phase = .proving }
        if state == "passed" { phase = .passed(ProviderStep.sampleFixed, 0.8) }
        if state == "failure" { error = "The API took too long to correct this text. Try again." }
        if state == "auth" { error = "The provider rejected the API key." }
    }
    #endif
}
