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
        indexedSources: @escaping @Sendable ([MediaIdentity], MediaItemKind?) -> [IndexedSource],
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
            indexedSources: { _, _ in union },
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
            indexedSources: { _, _ in [IndexedSource(accountID: "a", itemID: "420", kind: .movie)] },
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
            indexedSources: { _, _ in [] },
            indexedAccountIDs: { ["a"] }
        )
        var mutation = movieMutation()
        mutation.identities = []
        let expansion = await applier.expandTargets(for: mutation)
        XCTAssertEqual(expansion, .none)
        XCTAssertTrue(expansion.isConclusive)
    }
}
