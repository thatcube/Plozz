import Foundation

/// Secure, household-global storage for the user's **bring-your-own-key** TMDB API
/// token (Step 9).
///
/// The token is a credential, so — like every other secret in Plozz — it lives ONLY
/// in the Keychain (via ``SecureStoring``), never in `UserDefaults`, never logged, and
/// never committed. It is scoped household-global to match the Step 6 metadata provider
/// settings (which are app-wide, un-namespaced): one Apple TV, one TMDB key shared by
/// every profile, exactly like the servers and provider ordering it configures.
///
/// Abstracted behind ``TMDBUserKeyStoring`` so the Settings model can be unit-tested
/// with an in-memory ``SecureStoring`` double — real Keychain access isn't available in
/// unit tests.
public protocol TMDBUserKeyStoring: Sendable {
    /// The stored raw token, or `nil` when the user hasn't opted in (or stored a blank).
    func load() -> String?
    /// Persists (replacing any existing) the raw token. A blank/whitespace value is
    /// treated as opting out and removes the stored token instead.
    func save(_ token: String) throws
    /// Removes any stored token (opt out).
    func remove() throws
}

/// ``SecureStoring``-backed ``TMDBUserKeyStoring``. Stores the raw token under a single
/// fixed account key; the concrete secure store the caller injects (a household,
/// user-independent `KeychainStore` in production) decides the Keychain partition.
public struct TMDBUserKeyStore: TMDBUserKeyStoring {
    /// The Keychain account key the raw BYOK token is stored under.
    public static let account = "com.plozz.metadata.tmdbUserKey"

    private let secureStore: SecureStoring

    public init(secureStore: SecureStoring) {
        self.secureStore = secureStore
    }

    public func load() -> String? {
        guard let raw = secureStore.string(for: Self.account) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try remove()
            return
        }
        try secureStore.setString(trimmed, for: Self.account)
    }

    public func remove() throws {
        try secureStore.removeValue(for: Self.account)
    }
}
