import AppKit
import SwiftUI
import Security
import CryptoKit
import OopsCore

@MainActor final class Preferences: ObservableObject {
    @Published var status = ""

    // Sign in with ChatGPT
    @Published private(set) var chatGPTStatus: ChatGPTStatus = .signedOut {
        didSet { if case .signedIn = chatGPTStatus { providers.setChatGPT(signedIn: true) } else { providers.setChatGPT(signedIn: false) } }
    }
    @Published private(set) var signingIn = false
    @Published private(set) var disconnecting = false
    @Published var chatGPTMessage: String?
    @Published private(set) var models: [ChatGPTModel] = [] { didSet { providers.setChatGPT(models: models) } }
    @Published private(set) var modelsLoading = false
    @Published private(set) var modelsError: String?
    @Published var showWelcome = false

    /// One long-lived sign-in for the app: correction backends share it, so a refresh
    /// during a correction is visible here and vice versa.
    let chatGPT: ChatGPTAuth
    /// Providers, their catalogs and the chosen model.
    let providers: ProviderStore
    /// Debug-only fake sign-in for screenshots (`SettingsPreviewChatGPT`); inert unless set.
    let preview: ChatGPTPreview?
    private let defaults = UserDefaults.standard
    private var signInTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private var modelsFetchedAt: Date?

    init() {
        // A providers preview shows a fixed provider list and implies a signed-in ChatGPT preview.
        let preview = ChatGPTPreview(DebugFlags.chatGPT ?? (DebugFlags.providers ? "signedIn" : nil))
        self.preview = preview
        if let preview {
            chatGPT = ChatGPTAuth(store: InertChatGPTStore(), openBrowser: { _ in throw ChatGPTError("preview", "Preview only.") })
            providers = ProviderStore(chatGPT: chatGPT, preview: DebugFlags.providers)
            chatGPTStatus = preview.status
            models = preview.models
        } else {
            chatGPT = ChatGPTAuth(store: ChatGPTKeychainStore(), openBrowser: { url in
                let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                if !opened { throw ChatGPTError("browser_unavailable", "Oops couldn’t open your browser. Check your default browser, then try again.") }
            })
            providers = ProviderStore(chatGPT: chatGPT, preview: false)
            chatGPTStatus = chatGPT.status
            if let data = UserDefaults.standard.data(forKey: "chatgptModelCache") { models = (try? ChatGPTModels.decode(data)) ?? [] }
        }
        // didSet does not run during init.
        providers.setChatGPT(models: models)
        if case .signedIn = chatGPTStatus { providers.setChatGPT(signedIn: true) } else { providers.setChatGPT(signedIn: false) }
        providers.refreshClaude()
    }

    // MARK: Connection

    func refreshChatGPT() {
        guard preview == nil else { return }
        let current = chatGPT.status
        if current != chatGPTStatus { chatGPTStatus = current }
    }

    func signInWithChatGPT() {
        guard !signingIn else { return }
        chatGPTMessage = nil
        signingIn = true
        if let preview {
            // Simulated: no browser, no network, nothing stored.
            signInTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !Task.isCancelled else { return }
                self.signingIn = false
                self.chatGPTStatus = .signedIn(preview.identity)
                self.showWelcome = true
            }
            return
        }
        let auth = chatGPT
        signInTask = Task { [weak self] in
            do {
                try await auth.signIn()
                guard let self else { return }
                self.signingIn = false
                self.refreshChatGPT()
                if !self.defaults.bool(forKey: "chatgptWelcomeShown") {
                    self.defaults.set(true, forKey: "chatgptWelcomeShown")
                    self.showWelcome = true
                }
                self.modelsFetchedAt = nil
                self.loadModels()
            } catch {
                guard let self else { return }
                self.signingIn = false
                self.refreshChatGPT()
                if !Self.isCancellation(error) { self.chatGPTMessage = Self.friendly(error) }
            }
        }
    }

    func cancelSignIn() {
        chatGPT.cancelSignIn()
        signInTask?.cancel(); signInTask = nil
        signingIn = false
    }

    func signOut(forgetAccount: Bool = false) {
        cancelSignIn()
        chatGPTMessage = nil
        if preview != nil { chatGPTStatus = .signedOut; return }
        disconnecting = true
        let auth = chatGPT
        Task { [weak self] in
            var failure: String?
            do { try await auth.signOut(forgetAccount: forgetAccount) } catch { failure = Self.friendly(error) }
            guard let self else { return }
            self.disconnecting = false
            self.refreshChatGPT()
            self.chatGPTMessage = failure
        }
    }

    func openUsage() { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!) }

    // MARK: Models

    /// Refreshes the visible model list while signed in; the cached list shows meanwhile.
    func loadModels(force: Bool = false) {
        guard preview == nil, case .signedIn = chatGPTStatus, modelsTask == nil else { return }
        if !force, let fetched = modelsFetchedAt, Date().timeIntervalSince(fetched) < 300, !models.isEmpty { return }
        modelsLoading = true
        modelsError = nil
        let auth = chatGPT
        modelsTask = Task { [weak self] in
            do {
                let list = try await ChatGPTModels.list(using: auth)
                guard let self else { return }
                self.modelsFetchedAt = Date()
                if !list.isEmpty {
                    self.models = list
                    if let data = try? ChatGPTModels.encode(list) { self.defaults.set(data, forKey: "chatgptModelCache") }
                }
            } catch {
                guard let self else { return }
                if !Self.isCancellation(error) { self.modelsError = Self.friendly(error) }
                self.refreshChatGPT()
            }
            self?.modelsLoading = false
            self?.modelsTask = nil
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ChatGPTError)?.code == "cancelled"
    }
    /// ChatGPTError messages are already user-facing; anything else stays generic.
    private static func friendly(_ error: Error) -> String {
        (error as? ChatGPTError)?.message ?? (error as? CorrectionError)?.localizedDescription
            ?? "Couldn’t reach ChatGPT. Check your connection and try again."
    }
}

/// Never reads or writes Keychain or disk: used only by the screenshot preview.
private final class InertChatGPTStore: ChatGPTStore, @unchecked Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}

enum KeyStore {
    private static let service = "dev.0xmrwn.oops.API"
    private static func query(_ account: String) -> [String: Any] {
        let id = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    static func read(account: String) -> String {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ key: String, account: String) throws {
        let q = query(account)
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let result = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = q; item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CorrectionError.message("Could not save the API key to Keychain.") }
        } else if result != errSecSuccess { throw CorrectionError.message("Could not update the API key in Keychain.") }
    }
    static func remove(account: String) { SecItemDelete(query(account) as CFDictionary) }
}
