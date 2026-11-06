import Foundation
import Security

/// Who is signed in, from the verified ID token's profile claims.
public struct ChatGPTIdentity: Codable, Equatable, Sendable {
    public var email: String?
    public var name: String?
    /// The ChatGPT plan type the ID token names (`plus`, `pro`…), when it names one.
    public var plan: String?
    public init(email: String? = nil, name: String? = nil, plan: String? = nil) { self.email = email; self.name = name; self.plan = plan }
}

public enum ChatGPTStatus: Equatable, Sendable {
    case signedOut, signedIn(ChatGPTIdentity), reauthRequired
}

public extension ChatGPTAuth {
    var status: ChatGPTStatus {
        let profile = try? store.readProfile()
        if profile?.state == .reauthRequired { return .reauthRequired }
        guard let profile, profile.state == .connected, (try? store.readCredentials()) != nil else { return .signedOut }
        return .signedIn(profile.identity ?? .init())
    }
}

/// This Mac's registration: not secret, so it lives in a file. OpenAI's docs ask for the host ID to be
/// chosen before the first sign-in and kept for the host's lifetime, so it survives signing out and
/// forgetting the account; the issued client ID and subject survive signing out, so signing in again
/// reuses the same registration.
public struct ChatGPTProfile: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case connected, disconnected, reauthRequired }
    public var version = 1
    public var hostID: String
    public var clientID: String?
    public var subject: String?
    public var identity: ChatGPTIdentity?
    public var state: State
    /// Plan usage was declined or withdrawn: the next sign-in asks for consent again.
    public var consentNeeded: Bool?

    public init(hostID: String, clientID: String? = nil, subject: String? = nil, identity: ChatGPTIdentity? = nil,
                state: State = .disconnected, consentNeeded: Bool? = nil) {
        self.hostID = hostID; self.clientID = clientID; self.subject = subject; self.identity = identity
        self.state = state; self.consentNeeded = consentNeeded
    }

    /// A fresh host: a UUIDv4 URI, one of the host-ID formats OpenAI's overview accepts.
    static func newHost() -> ChatGPTProfile { ChatGPTProfile(hostID: "urn:uuid:" + UUID().uuidString.lowercased()) }
}

public struct ChatGPTTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    /// The token response's `earliest_refresh_at`: no proactive refresh before it.
    public var earliestRefreshAt: Date?
    public init(accessToken: String, refreshToken: String?, expiresAt: Date, earliestRefreshAt: Date?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.earliestRefreshAt = earliestRefreshAt
    }
}

/// The secret part, kept in the Keychain.
public struct ChatGPTCredentials: Codable, Equatable, Sendable {
    /// A refresh answer saved before its ID token could be verified. The old refresh token is spent
    /// once the server rotates it, so the answer is kept; it is used only after verification.
    public struct Pending: Codable, Equatable, Sendable {
        public var tokens: ChatGPTTokens
        public var scopes: [String]
        public var idToken: String
        public var receivedAt: Date
        public init(tokens: ChatGPTTokens, scopes: [String], idToken: String, receivedAt: Date) {
            self.tokens = tokens; self.scopes = scopes; self.idToken = idToken; self.receivedAt = receivedAt
        }
    }
    public var clientID: String
    public var scopes: [String]
    public var idToken: String
    public var tokens: ChatGPTTokens
    public var pending: Pending?
    public init(clientID: String, scopes: [String], idToken: String, tokens: ChatGPTTokens, pending: Pending? = nil) {
        self.clientID = clientID; self.scopes = scopes; self.idToken = idToken; self.tokens = tokens; self.pending = pending
    }
}

public protocol ChatGPTStore: AnyObject, Sendable {
    func readProfile() throws -> ChatGPTProfile?
    func writeProfile(_ profile: ChatGPTProfile) throws
    func readCredentials() throws -> ChatGPTCredentials?
    func writeCredentials(_ credentials: ChatGPTCredentials) throws
    func deleteCredentials() throws
    /// Runs `body` while no other process using this store runs its own: refresh tokens rotate, so two
    /// processes refreshing at once would spend the same one (OpenAI's docs: serialize refreshes).
    func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T
}

public extension ChatGPTStore {
    func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T { try await body() }
}

/// Credentials in the login Keychain, readable only while this Mac is unlocked and never synced; the
/// profile in Application Support, owner-only.
public final class ChatGPTKeychainStore: ChatGPTStore, @unchecked Sendable {
    public static let service = "dev.0xmrwn.oops.ChatGPT"
    private static let account = "default"
    private let directory: URL
    private var profileURL: URL { directory.appendingPathComponent("profile.json") }

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("oops/ChatGPT", isDirectory: true)
    }

    public func readProfile() throws -> ChatGPTProfile? {
        guard let data = try? Data(contentsOf: profileURL) else { return nil }
        // An unreadable profile only costs a new host ID and a new registration.
        guard let profile = try? JSONDecoder().decode(ChatGPTProfile.self, from: data), profile.version == 1 else { return nil }
        return profile
    }

    public func writeProfile(_ profile: ChatGPTProfile) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(profile).write(to: profileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
        } catch { throw ChatGPTError.named("storage_failed") }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
    }

    public func readCredentials() throws -> ChatGPTCredentials? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ChatGPTError.named("storage_failed") }
        guard let credentials = try? JSONDecoder().decode(ChatGPTCredentials.self, from: data) else { throw ChatGPTError.named("storage_invalid") }
        return credentials
    }

    public func writeCredentials(_ credentials: ChatGPTCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { throw ChatGPTError.named("storage_failed") }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ChatGPTError.named("storage_failed") }
    }

    public func deleteCredentials() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatGPTError.named("storage_failed") }
    }

    /// An advisory `flock` on a file beside the profile, shared by the app and `oops-eval`.
    public func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("refresh.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        // No lock file (a read-only home, say): carry on unlocked rather than block sign-in.
        guard descriptor >= 0 else { return try await body() }
        defer { close(descriptor) }
        // A refresh is one HTTPS round trip; give up waiting long after any honest one finishes.
        var waited = 0
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0, waited < 400 { waited += 1; try await Task.sleep(for: .milliseconds(50)) }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }
}
