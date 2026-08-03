import Foundation
import CoreSecureStore
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

/// Keychain-backed token store for AniList, on the shared synced box so this
/// sign-in reaches the account's other devices.
public final class KeychainAniListTokenStore: AniListTokenStoring, @unchecked Sendable {
    private let box: SyncedTokenBox<AniListTokens>

    public init(
        service: String = "com.plozz.app.tokens",
        account: String = "anilist.oauth",
        namespace: String? = nil
    ) {
        box = SyncedTokenBox(
            service: service,
            account: account,
            namespace: namespace
        )
    }

    public func setNamespace(_ namespace: String?) { box.setNamespace(namespace) }
    public func load() -> AniListTokens? { box.load() }
    public func save(_ tokens: AniListTokens) throws { try box.save(tokens) }
    public func clear() throws { try box.clear() }
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
