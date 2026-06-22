import Foundation
#if canImport(Security)
import Security
#endif

/// Persists the Trakt OAuth tokens. Abstracted behind a protocol so the service
/// can be unit-tested with an in-memory double — real Keychain access isn't
/// available in unit tests.
public protocol TraktTokenStoring: Sendable {
    func load() -> TraktTokens?
    func save(_ tokens: TraktTokens) throws
    func clear() throws
}

#if canImport(Security)
/// `Security.framework`-backed token store using a single generic-password item
/// holding the JSON-encoded `TraktTokens` blob.
///
/// Mirrors the app's existing Keychain conventions (see `FeatureAuth.KeychainStore`):
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the token survives a
/// reboot (tvOS has no passcode prompt) but never leaves the device or syncs to
/// iCloud. Kept self-contained here so the service stays decoupled from FeatureAuth.
public struct KeychainTraktTokenStore: TraktTokenStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.plozz.app.tokens", account: String = "trakt.oauth") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func load() -> TraktTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TraktTokens.self, from: data)
    }

    public func save(_ tokens: TraktTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        var query = baseQuery
        // Upsert: delete any existing item first, then add.
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw TraktTokenStoreError.unexpectedStatus(status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TraktTokenStoreError.unexpectedStatus(status)
        }
    }
}

public enum TraktTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}
#endif

/// In-memory token store for tests, previews, and non-Apple hosts. **Not** secure.
public final class InMemoryTraktTokenStore: TraktTokenStoring, @unchecked Sendable {
    private var tokens: TraktTokens?
    private let lock = NSLock()

    public init(tokens: TraktTokens? = nil) {
        self.tokens = tokens
    }

    public func load() -> TraktTokens? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: TraktTokens) throws {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}
