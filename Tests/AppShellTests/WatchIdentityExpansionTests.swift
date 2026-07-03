import XCTest
import CoreModels
import TraktService
import SimklService
import AniListService
import MALService
@testable import AppShell

/// Unit tests for ``AppShellWatchMutationApplier``'s **movie / series** identity
/// expansion — the warm-race fix. A title stopped before the eager identity index
/// finished warming must keep re-resolving its cross-server target set on each
/// drain (kicked after every warm publish) and only conclude once every active
/// account has been indexed, so the fan-out reaches all servers even when the
/// user played + backed out during the cold window.
final class WatchIdentityExpansionTests: XCTestCase {
    private func applier(
        allAccounts: @escaping @Sendable () async -> [String],
        indexedSources: @escaping @Sendable ([MediaIdentity], MediaItemKind?, String?, Int?) -> [IndexedSource],
        indexedAccountIDs: @escaping @Sendable () -> Set<String>,
        maxAttempts: Int = 6
    ) -> AppShellWatchMutationApplier {
        AppShellWatchMutationApplier(
            resolveProvider: { _ in nil },
            traktScrobbler: { DisabledTraktScrobbler() },
            simklScrobbler: { DisabledSimklScrobbler() },
            anilistScrobbler: { DisabledAniListScrobbler() },
            malScrobbler: { DisabledMALScrobbler() },
            allAccountIDs: allAccounts,
            indexedSeriesSources: { _ in [] },
            indexedSources: indexedSources,
            indexedAccountIDs: indexedAccountIDs,
            maxIdentityExpansionAttempts: maxAttempts
        )
    }

    private func movieMutation(attempts: Int = 0) -> WatchMutation {
        WatchMutation(
            capturedAt: Date(),
            canonicalMediaID: "imdb:tt6718170",
            resumePosition: 1647,
            targets: [WatchMutationTarget(accountID: "a", itemID: "420")],
            attempts: attempts,
            expansionPending: true,
            identities: [.external(source: "imdb", value: "tt6718170")]
        )
    }

    /// While the index is cold (only the origin warm), expansion is INCONCLUSIVE
    /// for every not-yet-indexed account, so the mutation stays queued. Once every
    /// account is indexed the union is complete and the expansion is conclusive.
    func testExpansionGrowsWithIndexAndConcludesWhenAllWarm() async {
        var indexed: Set<String> = ["a"]
        var union: [IndexedSource] = [IndexedSource(accountID: "a", itemID: "420", providerKind: .plex, kind: .movie)]
        let applier = applier(
            allAccounts: { ["a", "b", "c", "d"] },
            indexedSources: { _, _, _, _ in union },
            indexedAccountIDs: { indexed }
        )
        let mutation = movieMutation()

        let cold = await applier.expandTargets(for: mutation)
        XCTAssertFalse(cold.isConclusive, "A partially-warm index must keep expansion pending")
        XCTAssertEqual(Set(cold.inconclusiveAccountIDs), ["b", "c", "d"])
        XCTAssertEqual(Set(cold.targets.map(\.id)), ["a:420"])

        // The other accounts finish warming.
        indexed = ["a", "b", "c", "d"]
        union = [
            IndexedSource(accountID: "a", itemID: "420", providerKind: .plex, kind: .movie),
            IndexedSource(accountID: "b", itemID: "6950", providerKind: .plex, kind: .movie),
            IndexedSource(accountID: "c", itemID: "j-1", providerKind: .jellyfin, kind: .movie),
            IndexedSource(accountID: "d", itemID: "j-2", providerKind: .jellyfin, kind: .movie)
        ]
        let warm = await applier.expandTargets(for: mutation)
        XCTAssertTrue(warm.isConclusive, "Once every active account is indexed the union is complete")
        XCTAssertEqual(Set(warm.targets.map(\.id)), ["a:420", "b:6950", "c:j-1", "d:j-2"])
    }

    /// A permanently-unreachable (never-indexing) account can't keep a mutation
    /// queued forever: once the attempt budget is spent, expansion is treated as
    /// conclusive with whatever the index currently knows.
    func testAttemptBudgetForcesConclusionSoOutboxCantLeak() async {
        let applier = applier(
            allAccounts: { ["a", "ghost"] },
            indexedSources: { _, _, _, _ in [IndexedSource(accountID: "a", itemID: "420", kind: .movie)] },
            indexedAccountIDs: { ["a"] }, // "ghost" never indexes
            maxAttempts: 3
        )
        let young = await applier.expandTargets(for: movieMutation(attempts: 2))
        XCTAssertFalse(young.isConclusive, "Below the budget it keeps retrying the missing account")

        let exhausted = await applier.expandTargets(for: movieMutation(attempts: 3))
        XCTAssertTrue(exhausted.isConclusive, "At the budget it concludes so the mutation can prune")
        XCTAssertEqual(Set(exhausted.targets.map(\.id)), ["a:420"])
    }

    /// A title with no strong identity can't be index-matched, so identity
    /// expansion is a conclusive no-op (the origin write, added by the factory,
    /// still stands).
    func testIdentitylessMutationIsConclusiveNoOp() async {
        let applier = applier(
            allAccounts: { ["a", "b"] },
            indexedSources: { _, _, _, _ in [] },
            indexedAccountIDs: { ["a"] }
        )
        var mutation = movieMutation()
        mutation.identities = []
        let expansion = await applier.expandTargets(for: mutation)
        XCTAssertEqual(expansion, .none)
        XCTAssertTrue(expansion.isConclusive)
    }

    // MARK: - Split-guard: a bad shared external id must not cross-mark

    /// Real-world bug (Scream 6 tagged with Scream 7's TMDb id): marking Scream 7
    /// watched must NOT fan the write out to the mis-tagged Scream 6 on another
    /// server. The factory persists the played title's normalized-title/year anchor
    /// on the mutation, and the applier threads it into the index union so the
    /// impostor is split out at drain time — even though both films key on the same
    /// external id.
    func testMovieFanOutSplitsBadSharedExternalID() async {
        // The index knows both films under the SAME (wrong) tmdb id.
        let sharedID = MediaIdentity.external(source: "tmdb", value: "934433")
        let snapshot = IdentityIndexSnapshot(byIdentity: [
            sharedID: [
                IndexedSource(accountID: "plex", itemID: "s7", providerKind: .plex, kind: .movie,
                              normalizedTitle: MediaItemIdentity.normalizedTitle("Scream 7"), year: 2026),
                IndexedSource(accountID: "jf", itemID: "s6", providerKind: .jellyfin, kind: .movie,
                              normalizedTitle: MediaItemIdentity.normalizedTitle("Scream 6"), year: 2023)
            ]
        ])
        // The applier resolves the union through the guarded snapshot API, exactly
        // as AppState wires it in production.
        let applier = applier(
            allAccounts: { ["plex", "jf"] },
            indexedSources: { identities, kind, anchorTitle, anchorYear in
                snapshot.sources(forIdentities: identities, kind: kind, anchorTitle: anchorTitle, anchorYear: anchorYear)
            },
            indexedAccountIDs: { ["plex", "jf"] }
        )

        var scream7 = MediaItem(id: "s7", title: "Scream 7", kind: .movie, productionYear: 2026, providerIDs: ["Tmdb": "934433"])
        scream7.sourceAccountID = "plex"
        let mutation = WatchMutationFactory.playedToggle(item: scream7, played: true, primaryAccountID: "plex")
        let unwrapped = try! XCTUnwrap(mutation)

        // The factory captured the anchor.
        XCTAssertEqual(unwrapped.anchorTitle, "scream 7")
        XCTAssertEqual(unwrapped.anchorYear, 2026)

        // The fan-out reaches only Scream 7's own server, never the mis-tagged
        // Scream 6.
        let expansion = await applier.expandTargets(for: unwrapped)
        XCTAssertEqual(Set(expansion.targets.map(\.id)), ["plex:s7"], "Scream 6 must not be marked watched")
    }
}
