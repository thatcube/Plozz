import Foundation
import CoreSecureStore
#if canImport(Security)
import Security
#endif

/// Persists the Last.fm session key. Follows the same pattern as the other
/// tracker token stores (per-profile namespacing so each household profile can
/// link its own Last.fm account).
public protocol LastFmTokenStoring: Sendable {
    func load() -> LastFmTokens?
    func save(_ tokens: LastFmTokens) throws
    func clear() throws
    func setNamespace(_ namespace: String?)
}

#if canImport(Security)
/// Keychain-backed token store for Last.fm.

/// Keychain-backed token store for LastFm, on the shared synced box so this
/// sign-in reaches the account's other devices.
public final class KeychainLastFmTokenStore: LastFmTokenStoring, @unchecked Sendable {
    private let box: SyncedTokenBox<LastFmTokens>

    public init(
        service: String = "com.plozz.app.tokens",
        account: String = "lastfm.session",
        namespace: String? = nil
    ) {
        box = SyncedTokenBox(
            service: service,
            account: account,
            namespace: namespace
        )
    }

    public func setNamespace(_ namespace: String?) { box.setNamespace(namespace) }
    public func load() -> LastFmTokens? { box.load() }
    public func save(_ tokens: LastFmTokens) throws { try box.save(tokens) }
    public func clear() throws { try box.clear() }
}

public enum LastFmTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}
#endif

/// In-memory token store for tests/previews.
public final class InMemoryLastFmTokenStore: LastFmTokenStoring, @unchecked Sendable {
    private var storage: [String: LastFmTokens] = [:]
    private var namespace: String?
    private let lock = NSLock()

    public init(tokens: LastFmTokens? = nil) {
        if let tokens { storage[""] = tokens }
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        self.namespace = namespace
    }

    public func load() -> LastFmTokens? {
        lock.lock(); defer { lock.unlock() }
        return storage[namespace ?? ""]
    }

    public func save(_ tokens: LastFmTokens) throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = nil
    }
}
