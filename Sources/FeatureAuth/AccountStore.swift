import Foundation
import CoreModels
import CoreNetworking

/// Persists and restores the set of signed-in `Account`s and the active set.
///
/// Storage is split by sensitivity:
///  * **access tokens** → Keychain (`SecureStore`), one item per account keyed
///    by the account `id`;
///  * **non-secret metadata** (the `[Account]` list + active id set + device id)
///    → also the `SecureStore`.
///
/// Routing the metadata through the same store (rather than `UserDefaults`) is
/// deliberate: in production the injected store is the **user-independent
/// Keychain** (see `KeychainStore`), so the whole household's sign-in is shared
/// across Apple TV system users — sign in once. Under the
/// `com.apple.developer.user-management` entitlement `UserDefaults` would
/// otherwise be partitioned per system user, which would hide a primary user's
/// accounts from everyone else. `UserDefaults` is kept only for reading legacy
/// keys during the one-time upgrade migration.
///
/// Tokens and metadata are therefore never written to a plist or logged.
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
    /// Guards the one-time `UserDefaults` → `SecureStore` metadata migration.
    private var didMigrateMetadata = false

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
        ensureMetadataMigratedLocked()
        if let existing = secureStore.string(for: deviceIDKey) { return existing }
        let generated = UUID().uuidString
        try? secureStore.setString(generated, for: deviceIDKey)
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
        guard let ids = decodeIDs(secureStore.string(for: activeIDsKey)) else {
            // Default active set = every account.
            return accounts.map(\.id)
        }
        // Drop any stale ids that no longer correspond to a stored account.
        return ids.filter { known.contains($0) }
    }

    public func setActiveAccountIDs(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        let known = Set(loadAccountsLocked().map(\.id))
        persistActiveLocked(ids.filter { known.contains($0) })
    }

    public func token(for accountID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return secureStore.string(for: tokenKey(accountID))
    }

    public func add(_ account: Account, token: String) throws {
        lock.lock(); defer { lock.unlock() }
        var accounts = loadAccountsLocked()
        var persistedAccount = account
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            let existing = accounts[idx]
            let existingToken = secureStore.string(for: tokenKey(account.id))
            persistedAccount.credentialRevision = existingToken == token
                ? existing.credentialRevision
                : CredentialRevision()
            accounts[idx] = persistedAccount
        } else {
            accounts.append(persistedAccount)
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
        try? secureStore.removeValue(for: accountsKey)
        try? secureStore.removeValue(for: activeIDsKey)
        PlozzLog.auth.info("Cleared all accounts")
    }

    // MARK: Migration

    @discardableResult
    public func migrateLegacySessionIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        ensureMetadataMigratedLocked()
        // Already have accounts (new schema) → nothing to do (idempotent).
        guard secureStore.string(for: accountsKey) == nil else { return false }
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

    /// One-time copy of pre-entitlement metadata from `UserDefaults` into the
    /// (now household-shared) `SecureStore`. Keeps existing installs signed in
    /// when the `user-management` entitlement starts partitioning `UserDefaults`
    /// per Apple TV system user. Caller holds `lock`.
    private func ensureMetadataMigratedLocked() {
        guard !didMigrateMetadata else { return }
        didMigrateMetadata = true

        if secureStore.string(for: accountsKey) == nil,
           let json = string(fromDefaultsData: accountsKey) {
            try? secureStore.setString(json, for: accountsKey)
            if let activeJSON = string(fromDefaultsData: activeIDsKey) {
                try? secureStore.setString(activeJSON, for: activeIDsKey)
            }
            defaults.removeObject(forKey: accountsKey)
            defaults.removeObject(forKey: activeIDsKey)
        }

        if secureStore.string(for: deviceIDKey) == nil,
           let legacyDeviceID = defaults.string(forKey: deviceIDKey) {
            try? secureStore.setString(legacyDeviceID, for: deviceIDKey)
            defaults.removeObject(forKey: deviceIDKey)
        }
    }

    // MARK: Locked helpers (caller holds `lock`)

    private func tokenKey(_ accountID: String) -> String { tokenAccountPrefix + accountID }

    /// Reads a `UserDefaults` JSON `Data` value back as a UTF-8 string (used only
    /// by the upgrade migration above).
    private func string(fromDefaultsData key: String) -> String? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeIDs(_ json: String?) -> [String]? {
        guard let data = json?.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return ids
    }

    private func loadAccountsLocked() -> [Account] {
        ensureMetadataMigratedLocked()
        guard let data = secureStore.string(for: accountsKey)?.data(using: .utf8),
              let accounts = try? JSONDecoder().decode([Account].self, from: data) else {
            return []
        }
        let ordered = accounts.sorted { $0.addedAt < $1.addedAt }
        let revisionPresence = try? JSONDecoder().decode(
            [CredentialRevisionPresence].self,
            from: data
        )
        if revisionPresence?.contains(where: { $0.credentialRevision == nil }) == true {
            do {
               try saveAccountsLocked(ordered)
               PlozzLog.auth.info("Migrated account credential revisions")
            } catch {
               PlozzLog.auth.error("Account credential revision migration failed")
            }
        }
        return ordered
    }

    private func saveAccountsLocked(_ accounts: [Account]) throws {
        let ordered = accounts.sorted { $0.addedAt < $1.addedAt }
        let data = try JSONEncoder().encode(ordered)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AccountStoreError.encodingFailed
        }
        try secureStore.setString(json, for: accountsKey)
    }

    private func activeIDsLocked(within accounts: [Account]) -> [String] {
        let known = Set(accounts.map(\.id))
        guard let ids = decodeIDs(secureStore.string(for: activeIDsKey)) else {
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
        if let data = try? JSONEncoder().encode(ids),
           let json = String(data: data, encoding: .utf8) {
            try? secureStore.setString(json, for: activeIDsKey)
        }
    }
}

/// Errors local to `AccountStore` (kept module-portable; `KeychainError` only
/// exists where `Security` is importable).
private enum AccountStoreError: Error {
    case encodingFailed
}

private struct CredentialRevisionPresence: Decodable {
    let credentialRevision: CredentialRevision?
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
