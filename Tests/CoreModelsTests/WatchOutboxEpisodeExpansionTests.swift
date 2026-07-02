import XCTest
@testable import CoreModels

/// Applier double that records server writes and lets a test script the
/// cross-server twin **expansion** the reconciler should perform at drain time.
private final class ExpandingFakeApplier: WatchMutationApplying, @unchecked Sendable {
    struct PlayedWrite: Equatable { let played: Bool; let accountID: String; let itemID: String }

    private let lock = NSLock()
    private(set) var playedWrites: [PlayedWrite] = []
    private(set) var resumeWrites: [(seconds: TimeInterval, accountID: String, itemID: String)] = []
    private(set) var expandCallCount = 0

    /// Accounts whose writes currently fail (an offline/asleep server).
    var failingAccounts: Set<String> = []
    /// What `expandTargets` returns. Default: no expansion owed.
    var expansion: WatchTargetExpansion = .none

    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        if failingAccounts.contains(target.accountID) { throw AppError.serverUnreachable }
        lock.lock(); playedWrites.append(.init(played: played, accountID: target.accountID, itemID: target.itemID)); lock.unlock()
    }

    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        if failingAccounts.contains(target.accountID) { throw AppError.serverUnreachable }
        lock.lock(); resumeWrites.append((seconds, target.accountID, target.itemID)); lock.unlock()
    }

    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {}

    func expandTargets(for mutation: WatchMutation) async -> WatchTargetExpansion {
        lock.lock(); expandCallCount += 1; lock.unlock()
        return expansion
    }

    var playedAccounts: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(playedWrites.map(\.accountID)) }
}

private func episodeMutation(
    canonical: String = "tvdb:85552",
    capturedAt: Date,
    originAccount: String = "A",
    originItem: String = "A-ep",
    expansionPending: Bool = true
) -> WatchMutation {
    WatchMutation(
        capturedAt: capturedAt,
        canonicalMediaID: canonical,
        seasonNumber: 1,
        episodeNumber: 2,
        played: true,
        clearResume: true,
        targets: [WatchMutationTarget(accountID: originAccount, itemID: originItem)],
        episodeOrigin: EpisodeOrigin(accountID: originAccount, itemID: originItem),
        expansionPending: expansionPending
    )
}

/// Drain-time integration of episode-twin expansion: the reconciler must fan a
/// played episode out to the resolved twin, keep the origin write sacrosanct, and
/// retry only when expansion was inconclusive.
final class WatchOutboxEpisodeExpansionTests: XCTestCase {
    func testEpisodeExpandsToTwinAndConvergesBothServers() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-ep", providerKind: .plex)]
        )
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)

        await reconciler.enqueue(episodeMutation(capturedAt: Date()))
        await reconciler.drain()

        XCTAssertEqual(applier.playedAccounts, ["A", "B"], "Watch must converge origin AND the resolved twin")
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 0, "Fully converged ⇒ pruned")
    }

    func testInconclusiveExpansionKeepsMutationPendingButStillWritesOrigin() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(inconclusiveAccountIDs: ["B"]) // couldn't reach twin yet
        let store = InMemoryWatchMutationStore()
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        await reconciler.enqueue(episodeMutation(capturedAt: Date()))
        await reconciler.drain()

        XCTAssertEqual(applier.playedAccounts, ["A"], "Origin is never withheld waiting on a twin")
        let pendingAfterFirst = await reconciler.pendingCount
        XCTAssertEqual(pendingAfterFirst, 1, "Inconclusive expansion keeps the mutation alive to retry")

        // The twin server comes back: now expansion resolves it.
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-ep")]
        )
        await reconciler.drain()

        XCTAssertEqual(applier.playedAccounts, ["A", "B"], "Retry converges the twin once reachable")
        let pendingAfterSecond = await reconciler.pendingCount
        XCTAssertEqual(pendingAfterSecond, 0)
    }

    func testConclusiveNoTwinStillWritesOriginAndPrunes() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = .none   // confident: no other server hosts it / ambiguous skip
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)

        await reconciler.enqueue(episodeMutation(capturedAt: Date()))
        await reconciler.drain()

        XCTAssertEqual(applier.playedAccounts, ["A"])
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 0, "A conclusive no-twin result must not strand the mutation")
    }

    func testNonEpisodeMutationIsNeverExpanded() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-movie")]
        )
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)

        // A movie mutation: expansionPending defaults false.
        let movie = WatchMutation(
            capturedAt: Date(),
            canonicalMediaID: "imdb:tt1",
            played: true,
            clearResume: true,
            targets: [WatchMutationTarget(accountID: "A", itemID: "A-movie")]
        )
        await reconciler.enqueue(movie)
        await reconciler.drain()

        XCTAssertEqual(applier.expandCallCount, 0, "Movies must never trigger cross-server probing")
        XCTAssertEqual(applier.playedAccounts, ["A"])
    }

    func testExpansionIsIdempotentAcrossDrains() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-ep")]
        )
        // Origin write fails the first time so the mutation survives a second drain.
        applier.failingAccounts = ["A"]
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)

        await reconciler.enqueue(episodeMutation(capturedAt: Date()))
        await reconciler.drain()   // B written, A fails → still pending
        applier.failingAccounts = []
        await reconciler.drain()   // A written; B must NOT be written twice

        let bWrites = applier.playedWrites.filter { $0.accountID == "B" }
        XCTAssertEqual(bWrites.count, 1, "A resolved twin target must not be written twice")
        XCTAssertEqual(applier.playedAccounts, ["A", "B"])
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testLegacyOutboxMutationDecodesWithDefaultedExpansionFields() throws {
        // A pre-feature outbox entry has no `episodeOrigin` / `expansionPending` keys.
        let modern = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            canonicalMediaID: "imdb:tt1",
            played: true,
            clearResume: true,
            targets: [WatchMutationTarget(accountID: "A", itemID: "A1")]
        )
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as! [String: Any]
        json.removeValue(forKey: "episodeOrigin")
        json.removeValue(forKey: "expansionPending")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(WatchMutation.self, from: legacyData)
        XCTAssertNil(decoded.episodeOrigin)
        XCTAssertFalse(decoded.expansionPending, "Legacy entries must not suddenly start cross-server probing")
        XCTAssertEqual(decoded.targets, modern.targets)
    }
}

