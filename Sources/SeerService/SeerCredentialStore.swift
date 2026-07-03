import Foundation
#if canImport(Security)
import Security
#endif

/// The persisted form of a Seerr connection (server URL + API key + optional
/// user id), stored as a single JSON blob in the Keychain.
public struct SeerCredentials: Codable, Equatable, Sendable {
    public var baseURL: URL
    public var apiKey: String
    public var userId: Int?

    public init(baseURL: URL, apiKey: String, userId: Int? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.userId = userId
    }
}

/// Persists the Seerr credentials. Abstracted behind a protocol so the service
/// can be unit-tested with an in-memory double — real Keychain access isn't
/// available in unit tests.
///
/// Per-profile like ``TraktTokenStoring``: ``setNamespace(_:)`` scopes the stored
/// item so each household profile connects an independent Seerr account. `nil`
/// (the default/primary profile) keeps the legacy un-namespaced location.
public protocol SeerCredentialStoring: Sendable {
    func load() -> SeerCredentials?
    func save(_ credentials: SeerCredentials) throws
    func clear() throws
    func setNamespace(_ namespace: String?)
}

#if canImport(Security)
/// `Security.framework`-backed credential store using a single generic-password
/// item holding the JSON-encoded ``SeerCredentials`` blob.
///
/// Mirrors the app's Keychain conventions (see `TraktService.KeychainTraktTokenStore`):
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the credentials survive
/// a reboot (tvOS has no passcode prompt) but never leave the device or sync to
/// iCloud. A reference type with a lock-guarded namespace so the facade holds one
/// instance and observes profile switches.
public final class KeychainSeerCredentialStore: SeerCredentialStoring, @unchecked Sendable {
    private let service: String
    private let baseAccount: String
    private let lock = NSLock()
    private var namespace: String?

    public init(
        service: String = "com.plozz.app.tokens",
        account: String = "seer.credentials",
        namespace: String? = nil
    ) {
        self.service = service
        self.baseAccount = account
        self.namespace = namespace
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        self.namespace = namespace
    }

    private func currentAccount() -> String {
        lock.lock(); defer { lock.unlock() }
        if let namespace, !namespace.isEmpty {
            return "\(baseAccount).\(namespace)"
        }
        return baseAccount
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func load() -> SeerCredentials? {
        var query = baseQuery(account: currentAccount())
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SeerCredentials.self, from: data)
    }

    public func save(_ credentials: SeerCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var query = baseQuery(account: currentAccount())
        // Upsert: delete any existing item first, then add.
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SeerCredentialStoreError.unexpectedStatus(status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery(account: currentAccount()) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SeerCredentialStoreError.unexpectedStatus(status)
        }
    }
}

public enum SeerCredentialStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}
#endif

/// In-memory credential store for tests, previews, and non-Apple hosts. **Not**
/// secure. Namespace-keyed so each profile's credentials stay isolated (the
/// default profile uses the empty-string key).
public final class InMemorySeerCredentialStore: SeerCredentialStoring, @unchecked Sendable {
    private var storage: [String: SeerCredentials] = [:]
    private var namespace: String?
    private let lock = NSLock()

    public init(credentials: SeerCredentials? = nil) {
        if let credentials { storage[""] = credentials }
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        self.namespace = namespace
    }

    public func load() -> SeerCredentials? {
        lock.lock(); defer { lock.unlock() }
        return storage[namespace ?? ""]
    }

    public func save(_ credentials: SeerCredentials) throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = credentials
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = nil
    }
}
