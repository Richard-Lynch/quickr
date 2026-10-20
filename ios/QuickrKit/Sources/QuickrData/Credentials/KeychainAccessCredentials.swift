import Foundation
import Security
import Synchronization

/// Generic-password items, one per account, under one service. The app uses `SystemKeychain`;
/// tests and previews use `InMemoryKeychain`.
public protocol KeychainStore: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
}

/// A Keychain call failed. Carries the status only, never the item.
public struct KeychainError: Error, Sendable, Hashable, CustomStringConvertible {
    public var status: OSStatus

    public init(_ status: OSStatus) { self.status = status }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status) (\(message))"
    }
}

/// The real Keychain. Items are readable after the first unlock (background sync and the
/// extensions need them while locked) and never sync to iCloud or other devices. With no
/// `accessGroup`, an item goes to the first group in the app's `keychain-access-groups`
/// entitlement, `<team>.com.bahumia.quickr.shared`, which the widget and the NSE share.
public struct SystemKeychain: KeychainStore {
    public var service: String
    public var accessGroup: String?

    public init(service: String = "com.bahumia.quickr", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public func data(for account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status)
        }
    }

    public func set(_ data: Data, for account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }
}

/// A Keychain in memory, for tests and previews.
public final class InMemoryKeychain: KeychainStore {
    private let items = Mutex<[String: Data]>([:])
    /// Every call throws this instead, when set.
    private let failure = Mutex<KeychainError?>(nil)

    public init(_ items: [String: Data] = [:]) {
        self.items.withLock { $0 = items }
    }

    public func fail(with error: KeychainError?) { failure.withLock { $0 = error } }

    public var accounts: [String] { items.withLock { Array($0.keys).sorted() } }

    public func data(for account: String) throws -> Data? {
        if let error = failure.withLock({ $0 }) { throw error }
        return items.withLock { $0[account] }
    }

    public func set(_ data: Data, for account: String) throws {
        if let error = failure.withLock({ $0 }) { throw error }
        items.withLock { $0[account] = data }
    }

    public func delete(_ account: String) throws {
        if let error = failure.withLock({ $0 }) { throw error }
        items.withLock { $0[account] = nil }
    }
}

/// Which server an address belongs to, from the registry (`base_url` → `server_id`). Attached
/// once the session's registry is open; until then every address is unknown.
public final class ServerDirectory: Sendable {
    private let registry = Mutex<(any RegistryRepository)?>(nil)

    public init() {}

    public func attach(_ repository: any RegistryRepository) {
        registry.withLock { $0 = repository }
    }

    /// The server whose recorded address is `baseURL`, or nil.
    public func serverId(for baseURL: URL) async throws -> String? {
        guard let repository = registry.withLock({ $0 }) else { return nil }
        let key = KeychainAccessCredentials.addressKey(baseURL)
        return try await repository.servers().first { server in
            URL(string: server.baseURL).map(KeychainAccessCredentials.addressKey) == key
        }?.id
    }
}

/// Cloudflare Access service tokens in the Keychain (never in `UserDefaults`, `AppSettings` or a
/// log), one per server: each request gets the token of the server it goes to, so switching
/// servers never sends one server's secret to another, and changing one leaves the others alone.
///
/// An item is keyed by the server's `server_id` once the registry knows the address, and by the
/// normalised address before that (onboarding, a switch to a new server); `adopt` re-keys it to
/// the `server_id` once connected. Reads try the server's key, then its address's. Read on every
/// request, so a change applies to the next one without rebuilding anything.
public struct KeychainAccessCredentials: AccessCredentialsProvider {
    /// The single, app-wide item of the first SETTINGS build; `migrateLegacy` moves it.
    public static let legacyAccount = "cloudflare-access-service-token"
    static let prefix = "cloudflare-access"

    public let keychain: any KeychainStore
    public let directory: ServerDirectory

    public init(keychain: any KeychainStore = SystemKeychain(), directory: ServerDirectory = ServerDirectory()) {
        self.keychain = keychain
        self.directory = directory
    }

    // MARK: Keys

    /// scheme://host[:port][/path], lowercased scheme and host, no default port or trailing slash.
    public static func addressKey(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased()
        else { return url.absoluteString }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        let port = components.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port)\(path)"
    }

    static func account(serverId: String) -> String { "\(prefix):server:\(serverId)" }
    static func account(address url: URL) -> String { "\(prefix):url:\(addressKey(url))" }

    // MARK: Reading

    public func accessCredentials(for baseURL: URL) async throws -> AccessCredentials? {
        try await stored(for: baseURL)
    }

    /// The token for requests to `baseURL`: its server's, else its address's.
    public func stored(for baseURL: URL) async throws -> AccessCredentials? {
        if let serverId = try await directory.serverId(for: baseURL), let token = try stored(serverId: serverId) {
            return token
        }
        return try read(Self.account(address: baseURL))
    }

    public func stored(serverId: String) throws -> AccessCredentials? {
        try read(Self.account(serverId: serverId))
    }

    // MARK: Writing

    /// Stores (or, for nil, removes) the token for `baseURL`: under its server when the registry
    /// knows the address, else under the address. Removing clears both keys of that server only.
    public func save(_ credentials: AccessCredentials?, for baseURL: URL) async throws {
        let serverId = try await directory.serverId(for: baseURL)
        guard let credentials else {
            if let serverId { try keychain.delete(Self.account(serverId: serverId)) }
            try keychain.delete(Self.account(address: baseURL))
            return
        }
        try write(credentials, serverId.map(Self.account(serverId:)) ?? Self.account(address: baseURL))
    }

    /// Stores (or removes) a known server's token.
    public func save(_ credentials: AccessCredentials?, serverId: String) throws {
        guard let credentials else {
            try keychain.delete(Self.account(serverId: serverId))
            return
        }
        try write(credentials, Self.account(serverId: serverId))
    }

    /// After connecting `baseURL` to `serverId`: a token saved under the address becomes the
    /// server's (replacing an older one of that server's).
    public func adopt(baseURL: URL, serverId: String) throws {
        guard let token = try read(Self.account(address: baseURL)) else { return }
        try write(token, Self.account(serverId: serverId))
        try keychain.delete(Self.account(address: baseURL))
    }

    /// The first SETTINGS build kept one app-wide item: it becomes the active server's (by id, or
    /// by its address before the store is bound). Nothing happens with no legacy item, or with no
    /// server to give it to (it waits for the next launch).
    public func migrateLegacy(serverId: String?, baseURL: URL?) throws {
        guard let data = try keychain.data(for: Self.legacyAccount) else { return }
        let account: String
        if let serverId {
            account = Self.account(serverId: serverId)
        } else if let baseURL {
            account = Self.account(address: baseURL)
        } else {
            return
        }
        if try keychain.data(for: account) == nil { try keychain.set(data, for: account) }
        try keychain.delete(Self.legacyAccount)
    }

    private func read(_ account: String) throws -> AccessCredentials? {
        guard let data = try keychain.data(for: account) else { return nil }
        // A malformed item reads as none.
        return try? JSONDecoder().decode(Stored.self, from: data).credentials
    }

    private func write(_ credentials: AccessCredentials, _ account: String) throws {
        try keychain.set(try JSONEncoder().encode(Stored(credentials)), for: account)
    }

    private struct Stored: Codable {
        var clientId: String
        var clientSecret: String

        init(_ credentials: AccessCredentials) {
            clientId = credentials.clientId
            clientSecret = credentials.clientSecret
        }

        var credentials: AccessCredentials { AccessCredentials(clientId: clientId, clientSecret: clientSecret) }
    }
}

extension AccessCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// What a form typed: both fields empty is no token; otherwise both are needed, as single-line
    /// header values. Whitespace around each is dropped.
    public static func validated(clientId: String, clientSecret: String) -> Result<AccessCredentials?, Problem> {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty && secret.isEmpty { return .success(nil) }
        if id.isEmpty { return .failure(.missingClientId) }
        if secret.isEmpty { return .failure(.missingClientSecret) }
        let bad = { (s: String) in s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0.value > 0x7E }
        }
        if bad(id) || bad(secret) { return .failure(.invalidCharacters) }
        return .success(AccessCredentials(clientId: id, clientSecret: secret))
    }

    public enum Problem: Error, Sendable, Hashable, CustomStringConvertible {
        case missingClientId
        case missingClientSecret
        case invalidCharacters

        public var description: String {
            switch self {
            case .missingClientId: "Enter the Client ID too (it ends in .access)."
            case .missingClientSecret: "Enter the Client Secret too."
            case .invalidCharacters: "Paste the Client ID and Secret exactly as Cloudflare shows them."
            }
        }
    }

    /// The Client ID with the secret hidden, so the token never reaches a log or a crash report.
    public var description: String { "AccessCredentials(clientId: \(clientId), clientSecret: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["clientId": clientId, "clientSecret": "<redacted>"]) }
}
