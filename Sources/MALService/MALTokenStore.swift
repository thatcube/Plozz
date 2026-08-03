import Foundation
import CoreSecureStore
#if canImport(Security)
import Security
#endif

/// Persists MAL OAuth tokens.
public protocol MALTokenStoring: Sendable {
    func load() -> MALTokens?
    func save(_ tokens: MALTokens) throws
    func clear() throws
    func setNamespace(_ namespace: String?)
}

#if canImport(Security)
/// Keychain-backed token store for MAL.

/// Keychain-backed token store for MAL, on the shared synced box so this
/// sign-in reaches the account's other devices.
public final class KeychainMALTokenStore: MALTokenStoring, @unchecked Sendable {
    private let box: SyncedTokenBox<MALTokens>

    public init(
        service: String = "com.plozz.app.tokens",
        account: String = "mal.oauth",
        namespace: String? = nil
    ) {
        box = SyncedTokenBox(
            service: service,
            account: account,
            namespace: namespace
        )
    }

    public func setNamespace(_ namespace: String?) { box.setNamespace(namespace) }
    public func load() -> MALTokens? { box.load() }
    public func save(_ tokens: MALTokens) throws { try box.save(tokens) }
    public func clear() throws { try box.clear() }
}

public enum MALTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}
#endif

/// In-memory token store for tests/previews.
public final class InMemoryMALTokenStore: MALTokenStoring, @unchecked Sendable {
    private var storage: [String: MALTokens] = [:]
    private var namespace: String?
    private let lock = NSLock()

    public init(tokens: MALTokens? = nil) {
        if let tokens { storage[""] = tokens }
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        self.namespace = namespace
    }

    public func load() -> MALTokens? {
        lock.lock(); defer { lock.unlock() }
        return storage[namespace ?? ""]
    }

    public func save(_ tokens: MALTokens) throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = nil
    }
}
