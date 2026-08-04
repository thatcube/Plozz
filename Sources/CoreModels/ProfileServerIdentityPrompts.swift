import Foundation

/// Whether switching a server on for a profile owes an identity answer.
///
/// Turning a server on is the same decision the new-profile setup step asks, and
/// it has the same consequence: the watchlist import reads that server as
/// whoever the profile plays as, and with no binding that's the account owner.
/// Silently importing the owner's watchlist into a child's profile is exactly
/// what setup exists to prevent — so enabling a server later has to ask too.
///
/// Shared by both shells rather than reimplemented per platform. The rule for
/// *when* to ask is subtle, and the first version of it lived in the tvOS
/// coordinator alone — which left the iOS Settings toggle as a second, unguarded
/// door to the same leak. The PRESENTATION differs per platform (a full-screen
/// step on tvOS, a sheet on iOS); the policy does not, so only the policy is
/// here.
///
/// The pending set itself lives on the `Profile` record
/// (`accountsAwaitingIdentity`), not in memory. Asking is only half the job: the
/// import has to actually WAIT for the answer, and it has to still be waiting
/// after a relaunch — an in-memory question is forgotten on restart while the
/// enabled-but-unidentified server is still there, importing as the owner every
/// launch.
public enum ProfileServerIdentityPolicy {
    /// - Parameters:
    ///   - provider: only Plex has multiple identities to choose between.
    ///   - hasExistingBinding: a profile that already chose a user on this
    ///     account isn't asked again.
    public static func shouldAsk(
        provider: ProviderKind,
        hasExistingBinding: Bool
    ) -> Bool {
        provider == .plex && !hasExistingBinding
    }
}

extension Profile {
    /// Records that `accountID` was switched on and owes an identity answer.
    ///
    /// - Returns: `true` if this changed anything, so callers can skip a
    ///   redundant persist.
    @discardableResult
    public mutating func noteAccountAwaitingIdentity(_ accountID: String) -> Bool {
        var pending = pendingIdentityAccountIDs
        guard !pending.contains(accountID) else { return false }
        pending.append(accountID)
        // Sorted so the order is stable across launches rather than following
        // insertion or Set hashing — otherwise "answer one, get asked the next"
        // jumps around between runs.
        accountsAwaitingIdentity = pending.sorted()
        return true
    }

    /// Clears the question for `accountID` — answered, declined, or the server
    /// was switched back off. Declining counts: the point is to ask once, not to
    /// nag, and an unanswered question must not gate the import forever.
    @discardableResult
    public mutating func resolveAccountAwaitingIdentity(_ accountID: String) -> Bool {
        let pending = pendingIdentityAccountIDs
        guard pending.contains(accountID) else { return false }
        let remaining = pending.filter { $0 != accountID }
        // Absence, not `[]`: the sync layer requires a record to round-trip
        // byte-identically, and an empty array is not the same bytes as no key.
        accountsAwaitingIdentity = remaining.isEmpty ? nil : remaining
        return true
    }
}
