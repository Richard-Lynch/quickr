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

/// The Cloudflare Access service token, in the Keychain (never in `UserDefaults`, `AppSettings`
/// or a log). One token for the app: it is sent to whichever server is active. Read on every
/// request, so a change in Settings applies to the next request without rebuilding anything.
public struct KeychainAccessCredentials: AccessCredentialsProvider {
    public static let account = "cloudflare-access-service-token"

    public let keychain: any KeychainStore

    public init(keychain: any KeychainStore = SystemKeychain()) {
        self.keychain = keychain
    }

    public func accessCredentials() async throws -> AccessCredentials? {
        try stored()
    }

    /// The stored token, or nil. A malformed item reads as none.
    public func stored() throws -> AccessCredentials? {
        guard let data = try keychain.data(for: Self.account) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data).credentials
    }

    /// Stores `credentials`, or removes the token for nil.
    public func save(_ credentials: AccessCredentials?) throws {
        guard let credentials else {
            try keychain.delete(Self.account)
            return
        }
        let data = try JSONEncoder().encode(Stored(credentials))
        try keychain.set(data, for: Self.account)
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
