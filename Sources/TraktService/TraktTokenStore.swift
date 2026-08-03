import Foundation
import CoreSecureStore
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
    /// Switches which profile's tokens this store reads and writes. Pass `nil`
    /// for the default/primary profile, which keeps the legacy un-namespaced
    /// storage location (backward compatible with already-connected devices);
    /// any other namespace scopes tokens to that household profile.
    func setNamespace(_ namespace: String?)
}

#if canImport(Security)
/// `Security.framework`-backed token store using a single generic-password item
/// holding the JSON-encoded `TraktTokens` blob.
///
/// Mirrors the app's existing Keychain conventions (see `FeatureAuth.KeychainStore`):
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so the token survives a
/// reboot (tvOS has no passcode prompt) but never leaves the device or syncs to
/// iCloud. Kept self-contained here so the service stays decoupled from FeatureAuth.
///
/// Per-profile: the Keychain account is the base account for the default profile
/// (`nil` namespace → `trakt.oauth`, backward compatible) and `trakt.oauth.<ns>`
/// for any other household profile, so each profile connects an independent Trakt
/// account. A reference type with a lock-guarded namespace so the facade and the
/// scrobbler actor share one instance and both observe profile switches.

/// Keychain-backed token store for Trakt, on the shared synced box so this
/// sign-in reaches the account's other devices.
public final class KeychainTraktTokenStore: TraktTokenStoring, @unchecked Sendable {
    private let box: SyncedTokenBox<TraktTokens>

    public init(
        service: String = "com.plozz.app.tokens",
        account: String = "trakt.oauth",
        namespace: String? = nil
    ) {
        box = SyncedTokenBox(
            service: service,
            account: account,
            namespace: namespace
        )
    }

    public func setNamespace(_ namespace: String?) { box.setNamespace(namespace) }
    public func load() -> TraktTokens? { box.load() }
    public func save(_ tokens: TraktTokens) throws { try box.save(tokens) }
    public func clear() throws { try box.clear() }
}

public enum TraktTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}
#endif

/// In-memory token store for tests, previews, and non-Apple hosts. **Not** secure.
/// Namespace-keyed so each profile's tokens stay isolated (the default profile
/// uses the empty-string key).
public final class InMemoryTraktTokenStore: TraktTokenStoring, @unchecked Sendable {
    private var storage: [String: TraktTokens] = [:]
    private var namespace: String?
    private let lock = NSLock()

    public init(tokens: TraktTokens? = nil) {
        if let tokens { storage[""] = tokens }
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        self.namespace = namespace
    }

    public func load() -> TraktTokens? {
        lock.lock(); defer { lock.unlock() }
        return storage[namespace ?? ""]
    }

    public func save(_ tokens: TraktTokens) throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = nil
    }
}
