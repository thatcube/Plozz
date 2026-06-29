import Foundation
#if canImport(Security)
import Security
#endif

/// Persists AniList OAuth tokens.
public protocol AniListTokenStoring: Sendable {
    func load() -> AniListTokens?
    func save(_ tokens: AniListTokens) throws
    func clear() throws
    func setNamespace(_ namespace: String?)
}

#if canImport(Security)
/// Keychain-backed token store for AniList.
public final class KeychainAniListTokenStore: AniListTokenStoring, @unchecked Sendable {
    private let service: String
    private let baseAccount: String
    private let lock = NSLock()
    private var namespace: String?

    public init(service: String = "com.plozz.app.tokens", account: String = "anilist.oauth", namespace: String? = nil) {
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

    public func load() -> AniListTokens? {
        var query = baseQuery(account: currentAccount())
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AniListTokens.self, from: data)
    }

    public func save(_ tokens: AniListTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        var query = baseQuery(account: currentAccount())
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AniListTokenStoreError.unexpectedStatus(status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery(account: currentAccount()) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AniListTokenStoreError.unexpectedStatus(status)
        }
    }
}

public enum AniListTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}
#endif

/// In-memory token store for tests/previews.
public final class InMemoryAniListTokenStore: AniListTokenStoring, @unchecked Sendable {
    private var storage: [String: AniListTokens] = [:]
    private var namespace: String?
    private let lock = NSLock()

    public init(tokens: AniListTokens? = nil) {
        if let tokens { storage[""] = tokens }
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        self.namespace = namespace
    }

    public func load() -> AniListTokens? {
        lock.lock(); defer { lock.unlock() }
        return storage[namespace ?? ""]
    }

    public func save(_ tokens: AniListTokens) throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = nil
    }
}
