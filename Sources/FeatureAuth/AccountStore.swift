import Foundation
import CoreModels
import CoreNetworking

/// Persists and restores the set of signed-in `Account`s and the active set.
///
/// Storage is split by sensitivity, exactly like the legacy single-session
/// `SessionStore`:
///  * **access tokens** → Keychain (`SecureStore`), one item per account keyed
///    by the account `id`;
///  * **non-secret metadata** (the `[Account]` list + active id set + device id)
///    → `UserDefaults`.
///
/// Tokens are therefore never written to a plist or logged. Relaunch restores
/// every account without re-login.
public protocol AccountPersisting: Sendable {
    /// Stable per-install device id, generated once and reused for all auth.
    func deviceID() -> String
    /// All persisted accounts, in stable (added-at) order.
    func loadAccounts() -> [Account]
    /// Ids of the accounts in the active set (subset of `loadAccounts`).
    func activeAccountIDs() -> [String]
    /// Replaces the active set (ids not present in the account list are ignored).
    func setActiveAccountIDs(_ ids: [String])
    /// The Keychain-stored token for `accountID`, if present.
    func token(for accountID: String) -> String?
    /// Adds (or replaces) an account and stores its token in the Keychain.
    func add(_ account: Account, token: String) throws
    /// Removes an account, deleting its token from the Keychain.
    func remove(id: String) throws
    /// Removes every account and token (full sign-out).
    func clearAll() throws
    /// One-time migration of a legacy single `UserSession` into the account
    /// list. Idempotent; returns `true` only when a migration actually ran.
    @discardableResult func migrateLegacySessionIfNeeded() -> Bool
}

public final class AccountStore: AccountPersisting, @unchecked Sendable {
    private let secureStore: SecureStore
    private let defaults: UserDefaults
    private let lock = NSLock()

    // New multi-account keys.
    private let accountsKey = "com.plozz.accounts.v1"
    private let activeIDsKey = "com.plozz.accounts.activeIDs"
    private let deviceIDKey = "com.plozz.session.deviceID" // reused from legacy
    private let tokenAccountPrefix = "com.plozz.account.token."

    // Legacy single-session keys (read once during migration).
    private let legacyMetadataKey = "com.plozz.session.metadata"
    private let legacyTokenAccount = "com.plozz.session.accessToken"

    #if canImport(Security)
    public init(secureStore: SecureStore = KeychainStore(), defaults: UserDefaults = .standard) {
        self.secureStore = secureStore
        self.defaults = defaults
    }
    #else
    public init(secureStore: SecureStore, defaults: UserDefaults = .standard) {
        self.secureStore = secureStore
        self.defaults = defaults
    }
    #endif

    // MARK: Device id

    public func deviceID() -> String {
        lock.lock(); defer { lock.unlock() }
        if let existing = defaults.string(forKey: deviceIDKey) { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: deviceIDKey)
        return generated
    }

    // MARK: Accounts

    public func loadAccounts() -> [Account] {
        lock.lock(); defer { lock.unlock() }
        return loadAccountsLocked()
    }

    public func activeAccountIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let accounts = loadAccountsLocked()
        let known = Set(accounts.map(\.id))
        guard let data = defaults.data(forKey: activeIDsKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            // Default active set = every account.
            return accounts.map(\.id)
        }
        // Drop any stale ids that no longer correspond to a stored account.
        return ids.filter { known.contains($0) }
    }

    public func setActiveAccountIDs(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        let known = Set(loadAccountsLocked().map(\.id))
        let filtered = ids.filter { known.contains($0) }
        if let data = try? JSONEncoder().encode(filtered) {
            defaults.set(data, forKey: activeIDsKey)
        }
    }

    public func token(for accountID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return secureStore.string(for: tokenKey(accountID))
    }

    public func add(_ account: Account, token: String) throws {
        lock.lock(); defer { lock.unlock() }
        var accounts = loadAccountsLocked()
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        // Token only ever lives in the Keychain.
        try secureStore.setString(token, for: tokenKey(account.id))
        try saveAccountsLocked(accounts)
        // New accounts join the active set by default.
        addToActiveSetLocked(account.id, within: accounts)
        PlozzLog.auth.info("Added account for user \(account.userName)")
    }

    public func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var accounts = loadAccountsLocked()
        accounts.removeAll { $0.id == id }
        try secureStore.removeValue(for: tokenKey(id))
        try saveAccountsLocked(accounts)
        var active = activeIDsLocked(within: accounts)
        active.removeAll { $0 == id }
        persistActiveLocked(active)
        PlozzLog.auth.info("Removed account \(id)")
    }

    public func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        for account in loadAccountsLocked() {
            try secureStore.removeValue(for: tokenKey(account.id))
        }
        defaults.removeObject(forKey: accountsKey)
        defaults.removeObject(forKey: activeIDsKey)
        PlozzLog.auth.info("Cleared all accounts")
    }

    // MARK: Migration

    @discardableResult
    public func migrateLegacySessionIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Already on the new schema → nothing to do (idempotent).
        guard defaults.data(forKey: accountsKey) == nil else { return false }
        guard let data = defaults.data(forKey: legacyMetadataKey),
              let metadata = try? JSONDecoder().decode(LegacyMetadata.self, from: data),
              let token = secureStore.string(for: legacyTokenAccount) else {
            return false
        }

        let account = Account(
            server: metadata.server,
            userID: metadata.userID,
            userName: metadata.userName,
            deviceID: metadata.deviceID
        )
        do {
            try secureStore.setString(token, for: tokenKey(account.id))
            try saveAccountsLocked([account])
            persistActiveLocked([account.id])
            // Retire the legacy records so we never migrate twice.
            secureStore.removeValueIgnoringError(for: legacyTokenAccount)
            defaults.removeObject(forKey: legacyMetadataKey)
            PlozzLog.auth.info("Migrated legacy session to multi-account store")
            return true
        } catch {
            PlozzLog.auth.error("Legacy session migration failed")
            return false
        }
    }

    // MARK: Locked helpers (caller holds `lock`)

    private func tokenKey(_ accountID: String) -> String { tokenAccountPrefix + accountID }

    private func loadAccountsLocked() -> [Account] {
        guard let data = defaults.data(forKey: accountsKey),
              let accounts = try? JSONDecoder().decode([Account].self, from: data) else {
            return []
        }
        return accounts.sorted { $0.addedAt < $1.addedAt }
    }

    private func saveAccountsLocked(_ accounts: [Account]) throws {
        let ordered = accounts.sorted { $0.addedAt < $1.addedAt }
        let data = try JSONEncoder().encode(ordered)
        defaults.set(data, forKey: accountsKey)
    }

    private func activeIDsLocked(within accounts: [Account]) -> [String] {
        let known = Set(accounts.map(\.id))
        guard let data = defaults.data(forKey: activeIDsKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return accounts.map(\.id)
        }
        return ids.filter { known.contains($0) }
    }

    private func addToActiveSetLocked(_ id: String, within accounts: [Account]) {
        var active = activeIDsLocked(within: accounts)
        if !active.contains(id) { active.append(id) }
        persistActiveLocked(active)
    }

    private func persistActiveLocked(_ ids: [String]) {
        if let data = try? JSONEncoder().encode(ids) {
            defaults.set(data, forKey: activeIDsKey)
        }
    }
}

/// Mirror of the legacy `SessionStore.Metadata` shape, decoded only to migrate.
private struct LegacyMetadata: Codable {
    var server: MediaServer
    var userID: String
    var userName: String
    var deviceID: String
}

private extension SecureStore {
    /// Best-effort delete used during migration cleanup.
    func removeValueIgnoringError(for key: String) {
        try? removeValue(for: key)
    }
}
