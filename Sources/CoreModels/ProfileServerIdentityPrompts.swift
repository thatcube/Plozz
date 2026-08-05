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
    /// The Plex accounts the watchlist import will read from, by id.
    ///
    /// Taken from the SAME collection the import fans out over
    /// (`AccountsProvidersModel.homeAccounts`), so the gate and the import can
    /// never disagree about which servers are in play.
    public static func importPlexAccountIDs(in accounts: [ResolvedAccount]) -> [String] {
        accounts.filter { $0.account.server.provider == .plex }.map(\.account.id)
    }

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

    /// Clears the question for `accountID` — answered, or the server was
    /// switched back off. See `declineAccountWatchlist` for backing out.
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

    /// Records that nobody said who this profile is on `accountID`, so its own
    /// watchlist must not be read.
    ///
    /// Backing out used to just clear the question, after which the server was
    /// read as the account OWNER — the exact outcome the question exists to
    /// prevent, reached by declining to answer it. Declining now means what it
    /// says. The server stays usable for browsing and playback; only its
    /// watchlist is left alone.
    @discardableResult
    public mutating func declineAccountWatchlist(_ accountID: String) -> Bool {
        var changed = resolveAccountAwaitingIdentity(accountID)
        var declined = declinedWatchlistAccountIDs
        if !declined.contains(accountID) {
            declined.append(accountID)
            watchlistDeclinedAccountIDs = declined.sorted()
            changed = true
        }
        return changed
    }

    /// Withdraws a decline — the profile chose an identity here, or the server
    /// was switched off and on again, so the question is live once more.
    @discardableResult
    public mutating func clearWatchlistDecline(_ accountID: String) -> Bool {
        let declined = declinedWatchlistAccountIDs
        guard declined.contains(accountID) else { return false }
        let remaining = declined.filter { $0 != accountID }
        watchlistDeclinedAccountIDs = remaining.isEmpty ? nil : remaining
        return true
    }
}

@MainActor
public extension ProfilesModel {
    /// The identity questions this profile can actually act on, in a stable order.
    ///
    /// ONE derivation, used both to gate the import and to choose which question
    /// to present — they were computed differently, and disagreeing is worse than
    /// either rule alone: the gate saw a pending id somewhere in the household and
    /// held the import, while the presenter picked the first RAW pending id, found
    /// no such account, and showed nothing. Deferred forever, asked never.
    ///
    /// - Parameter importAccountIDs: the Plex accounts the watchlist import will
    ///   ACTUALLY read from. Passed in rather than derived here so the gate and
    ///   the import can't disagree about which servers are in play — deriving it
    ///   from the profile's stored membership looked equivalent and wasn't: an
    ///   explicitly empty selection reads as "no servers" here while the import
    ///   falls back to the primary account, and a selection naming only servers
    ///   that are gone falls back to the whole household. Both fell through the
    ///   gate and imported as the account owner. Asking the import what it's
    ///   going to do removes the second, drifting definition.
    func actionableIdentityAccountIDs(
        forProfile profileID: String,
        importAccountIDs: [String]
    ) -> [String] {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return [] }
        let pending = Set(profile.pendingIdentityAccountIDs)
        guard !pending.isEmpty else { return [] }
        return importAccountIDs.filter { pending.contains($0) }.sorted()
    }

    /// Applies a synced membership set, asking who the profile watches as on any
    /// Plex server the sync just switched ON.
    ///
    /// Membership arriving over sync enables servers exactly as the local toggle
    /// does, and has exactly the same consequence — with no Home user bound, the
    /// watchlist import reads that server as the account OWNER. Guarding only the
    /// local toggle left the sync path as a second, quieter door into the same
    /// leak: a profile set up correctly on one device could inherit the owner's
    /// watchlist on another simply by syncing.
    ///
    /// - Parameter knownNonPlexAccountIDs: accounts this device knows are not
    ///   Plex. See `noteIdentityQuestions` for why unknown ids are recorded.
    func applySyncedMembership(
        _ accountIDs: [String],
        forProfile profileID: String,
        knownNonPlexAccountIDs: Set<String>
    ) {
        // The EXPLICIT selection: "never chose" means the profile defaults to
        // every server, and treating that as a set of enabled ids would report
        // nothing as newly enabled.
        let previous = Set(storedActiveAccountIDs(for: profileID) ?? [])
        setActiveAccountIDs(accountIDs, for: profileID)
        let newlyEnabled = Set(accountIDs).subtracting(previous)
        noteIdentityQuestions(
            for: newlyEnabled,
            forProfile: profileID,
            knownNonPlexAccountIDs: knownNonPlexAccountIDs
        )
    }

    /// Records the identity question for every account in `accountIDs` that could
    /// need one.
    ///
    /// - Parameter knownNonPlexAccountIDs: accounts this device knows are NOT
    ///   Plex, and so have no identity to choose. Everything else is treated as
    ///   possibly-Plex on purpose: synced membership can enable a server this
    ///   device hasn't signed into yet, so its provider is genuinely unknown
    ///   here, and declining to record the question means the leak just happens
    ///   later — when the account arrives, already enabled, with nothing pending.
    ///   Over-recording is safe because `actionableIdentityAccountIDs` narrows to
    ///   accounts that are present, Plex, and active before gating anything.
    func noteIdentityQuestions(
        for accountIDs: some Collection<String>,
        forProfile profileID: String,
        knownNonPlexAccountIDs: Set<String>
    ) {
        guard !accountIDs.isEmpty,
              var profile = profiles.first(where: { $0.id == profileID })
        else { return }
        var changed = false
        for accountID in accountIDs where !knownNonPlexAccountIDs.contains(accountID) {
            // Switching a server on again is a fresh start: whatever was
            // declined last time is being reconsidered, which is the only way
            // back from a decline.
            changed = profile.clearWatchlistDecline(accountID) || changed
            guard ProfileServerIdentityPolicy.shouldAsk(
                provider: .plex,
                hasExistingBinding: profile.homeUserBinding(forPlexAccount: accountID) != nil
            ) else { continue }
            changed = profile.noteAccountAwaitingIdentity(accountID) || changed
        }
        if changed { update(profile) }
    }

    /// The accounts this profile has declined to read a watchlist from.
    func declinedWatchlistAccountIDs(forProfile profileID: String) -> Set<String> {
        Set(
            profiles.first { $0.id == profileID }?
                .declinedWatchlistAccountIDs ?? []
        )
    }

    /// Records identity questions for a profile that has just ARRIVED over sync,
    /// covering the servers it already has switched on.
    ///
    /// A profile can reach this device in a later batch than its membership, so
    /// the membership was applied when there was no profile to write the question
    /// to — and being already-persisted, an identical later sync shows nothing
    /// newly enabled and never asks. A profile arriving for the first time is
    /// exactly one nobody here has been asked about, so asking is right.
    func noteIdentityQuestionsForArrivedProfile(
        _ profileID: String,
        knownNonPlexAccountIDs: Set<String>
    ) {
        noteIdentityQuestions(
            for: storedActiveAccountIDs(for: profileID) ?? [],
            forProfile: profileID,
            knownNonPlexAccountIDs: knownNonPlexAccountIDs
        )
    }

    /// Withdraws an account's pending identity question from EVERY profile.
    ///
    /// Call when the account is removed from the device. The question is
    /// persisted and gates the watchlist import, and once the account is gone
    /// there's no screen that can ask it — so leaving the entry behind defers
    /// every future import forever, silently, with nothing the user can do about
    /// it. A question that can no longer be answered has to be withdrawn.
    ///
    /// - Returns: `true` if the ACTIVE profile changed, so the caller knows to
    ///   release the import it was holding.
    @discardableResult
    func withdrawIdentityQuestions(forAccount accountID: String) -> Bool {
        var activeChanged = false
        for profile in profiles {
            var updated = profile
            guard updated.resolveAccountAwaitingIdentity(accountID) else { continue }
            update(updated)
            if profile.id == activeProfileID { activeChanged = true }
        }
        return activeChanged
    }
}
