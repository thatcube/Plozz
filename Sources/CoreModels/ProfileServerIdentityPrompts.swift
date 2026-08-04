import Foundation

/// Tracks servers a profile has switched on but not yet said who it watches as.
///
/// Turning a server on is the same decision the new-profile setup step asks, and
/// it has the same consequence: the watchlist import reads that server as
/// whoever the profile plays as, and with no binding that's the account owner.
/// Silently importing the owner's watchlist into a child's profile is exactly
/// what setup exists to prevent — so enabling a server later has to ask too.
///
/// Shared by both shells rather than reimplemented per platform. The rule for
/// *when* to ask is subtle (Plex only, and only when nothing is bound yet), and
/// the first version of it lived in the tvOS coordinator alone — which left the
/// iOS Settings toggle as a second, unguarded door to the same leak. The
/// PRESENTATION differs per platform (a full-screen step on tvOS, a sheet on
/// iOS); the policy does not, so only the policy lives here.
///
/// Keyed by profile so switching away and back doesn't lose the question.
public final class ProfileServerIdentityPrompts {
    private var pending: [String: Set<String>] = [:]

    public init() {}

    /// Records that `accountID` was enabled for `profileID` and needs an identity.
    ///
    /// - Parameters:
    ///   - provider: only Plex has multiple identities to choose between.
    ///   - hasExistingBinding: a profile that already chose a user on this
    ///     account isn't being asked again.
    public func note(
        accountID: String,
        profileID: String,
        provider: ProviderKind,
        hasExistingBinding: Bool
    ) {
        guard provider == .plex, !hasExistingBinding else { return }
        pending[profileID, default: []].insert(accountID)
    }

    /// The server this profile has enabled and not yet chosen an identity on.
    ///
    /// One at a time: enabling several servers asks about each in turn as the
    /// previous is resolved, rather than stacking presentations.
    public func pendingAccountID(for profileID: String) -> String? {
        // Sorted so the order is stable across launches instead of following Set
        // hashing — otherwise "answer one, get asked the next" jumps around.
        pending[profileID]?.sorted().first
    }

    /// Clears the question once an identity is chosen — or declined. Declining
    /// counts: the point is to ask once, not to nag.
    public func resolve(accountID: String, profileID: String) {
        pending[profileID]?.remove(accountID)
        if pending[profileID]?.isEmpty == true { pending[profileID] = nil }
    }

    /// Drops every pending question for a profile (it was deleted, or setup
    /// answered them all).
    public func clear(profileID: String) {
        pending[profileID] = nil
    }

    public func clearAll() {
        pending.removeAll()
    }
}
