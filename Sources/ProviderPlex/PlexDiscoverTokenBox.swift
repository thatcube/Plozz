import Foundation

/// A thread-safe, live-readable store of the account-level plex.tv tokens that
/// Discover (the watchlist) needs, keyed by `Account.id`.
///
/// Exists because of a timing problem with two bad answers. Switching to a Plex
/// Home user is a network round trip, so the token isn't known when the watchlist
/// destinations are built. Capturing it at construction time meant capturing
/// `nil` and silently falling back to the ACCOUNT OWNER's token — reading the
/// owner's watchlist into someone else's profile. Reading it through the
/// `@MainActor` model instead would need an actor hop from the destination's
/// non-isolated async methods.
///
/// So the token lives in a box: the identity model writes to it whenever an
/// override changes, and destinations read from it synchronously at the moment of
/// use. Values only — nothing here knows how to obtain a token.
///
/// Never persisted. Cleared alongside the in-memory overrides it mirrors.
public final class PlexDiscoverTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tokensByAccountID: [String: String] = [:]

    public init() {}

    public func token(for accountID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokensByAccountID[accountID]
    }

    public func setToken(_ token: String?, for accountID: String) {
        lock.lock(); defer { lock.unlock() }
        tokensByAccountID[accountID] = token
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        tokensByAccountID.removeAll()
    }
}
