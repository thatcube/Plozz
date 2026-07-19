import Foundation
import FeatureAuthCore

/// Persists the **server-scoped access tokens** resolved for *unprotected* Plex
/// Home users so subsequent launches (and profile picks) can install the right
/// identity **synchronously** — painting Home once with the correct token
/// instead of loading with the admin token and reloading when the async switch
/// lands. This is the cache that removes the startup double-load + its latency.
///
/// ## Why only unprotected users
/// PIN-protected Home users must re-prompt every launch (a persisted token would
/// defeat the PIN), so their tokens are **never** written here. Callers gate
/// this cache behind `binding.requiresPIN != true`. Unprotected users have no
/// PIN to bypass, and their token is no more sensitive than the admin token the
/// `AccountStore` already persists in the same Keychain.
///
/// ## Storage
/// Entries are keyed by `accountID` + `homeUserID` and live in a dedicated
/// Keychain service. A small JSON index (account → home-user ids) is kept
/// alongside them so an account removal / full sign-out can purge every cached
/// token for an account without a Keychain enumeration API.
public struct PlexHomeUserTokenCache {
    private let secureStore: SecureStore
    private static let indexKey = "__index__"

    public init(store: SecureStore) {
        self.secureStore = store
    }

    /// Default Keychain-backed cache, household-shared to match account scope.
    public static func makeDefault() -> PlexHomeUserTokenCache {
        #if canImport(Security)
        return PlexHomeUserTokenCache(store: KeychainStore(service: "com.plozz.app.plexhomeuser"))
        #else
        return PlexHomeUserTokenCache(store: InMemorySecureStore())
        #endif
    }

    private func entryKey(account: String, homeUser: String) -> String {
        "\(account)\u{1F}\(homeUser)"
    }

    /// The cached server-scoped token for an unprotected Home user, if any.
    func token(account: String, homeUser: String) -> String? {
        secureStore.string(for: entryKey(account: account, homeUser: homeUser))
    }

    /// Persists (upserts) a resolved token and records it in the index.
    func store(token: String, account: String, homeUser: String) {
        try? secureStore.setString(token, for: entryKey(account: account, homeUser: homeUser))
        var index = loadIndex()
        index[account, default: []].insert(homeUser)
        saveIndex(index)
    }

    /// Removes a single account/home-user entry (e.g. a binding became
    /// PIN-protected, so its token must no longer sit at rest).
    func remove(account: String, homeUser: String) {
        try? secureStore.removeValue(for: entryKey(account: account, homeUser: homeUser))
        var index = loadIndex()
        if var users = index[account] {
            users.remove(homeUser)
            if users.isEmpty { index[account] = nil } else { index[account] = users }
            saveIndex(index)
        }
    }

    /// Removes every cached token for an account (account removed / signed out).
    func removeAll(account: String) {
        var index = loadIndex()
        for homeUser in index[account] ?? [] {
            try? secureStore.removeValue(for: entryKey(account: account, homeUser: homeUser))
        }
        index[account] = nil
        saveIndex(index)
    }

    /// Removes every cached token across all accounts (full reset).
    func removeAll() {
        let index = loadIndex()
        for (account, users) in index {
            for homeUser in users {
                try? secureStore.removeValue(for: entryKey(account: account, homeUser: homeUser))
            }
        }
        try? secureStore.removeValue(for: Self.indexKey)
    }

    // MARK: Index

    private func loadIndex() -> [String: Set<String>] {
        guard let raw = secureStore.string(for: Self.indexKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded.mapValues(Set.init)
    }

    private func saveIndex(_ index: [String: Set<String>]) {
        let encodable = index.mapValues(Array.init)
        guard let data = try? JSONEncoder().encode(encodable),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        try? secureStore.setString(raw, for: Self.indexKey)
    }
}
