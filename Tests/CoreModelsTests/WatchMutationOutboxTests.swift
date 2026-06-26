import XCTest
@testable import CoreModels

// MARK: - Test applier

/// Records writes and lets a test fail specific accounts (offline servers) or
/// Trakt, so we can assert the reconciler retries instead of dropping a watch.
private final class FakeWatchApplier: WatchMutationApplying, @unchecked Sendable {
    struct PlayedWrite: Equatable { let played: Bool; let accountID: String; let itemID: String }
    struct ResumeWrite: Equatable { let seconds: TimeInterval; let accountID: String; let itemID: String }

    private let lock = NSLock()
    private(set) var playedWrites: [PlayedWrite] = []
    private(set) var resumeWrites: [ResumeWrite] = []
    private(set) var traktScrobbles: [TraktScrobbleIntent] = []

    /// Accounts whose writes currently fail (simulating an offline / asleep server).
    var failingAccounts: Set<String> = []
    /// When true, Trakt mirroring throws (simulating an offline tracker).
    var traktFails = false

    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        if failingAccounts.contains(target.accountID) { throw AppError.serverUnreachable }
        lock.lock(); playedWrites.append(.init(played: played, accountID: target.accountID, itemID: target.itemID)); lock.unlock()
    }

    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget) async throws {
        if failingAccounts.contains(target.accountID) { throw AppError.serverUnreachable }
        lock.lock(); resumeWrites.append(.init(seconds: seconds, accountID: target.accountID, itemID: target.itemID)); lock.unlock()
    }

    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {
        if traktFails { throw AppError.serverUnreachable }
        lock.lock(); traktScrobbles.append(intent); lock.unlock()
    }
}

private func target(_ account: String, _ item: String) -> WatchMutationTarget {
    WatchMutationTarget(accountID: account, itemID: item)
}

private func playedMutation(canonical: String = "imdb:tt1", played: Bool = true, capturedAt: Date, targets: [WatchMutationTarget], trakt: TraktScrobbleIntent? = nil) -> WatchMutation {
    WatchMutation(
        capturedAt: capturedAt,
        canonicalMediaID: canonical,
        played: played,
        clearResume: played,
        targets: targets,
        trakt: trakt
    )
}

// MARK: - Cold start

final class WatchOutboxColdStartTests: XCTestCase {
    /// A brand-new install: an empty file store must load `.empty` without throwing
    /// or force-unwrapping, the reconciler must start at zero pending, and a drain on
    /// an empty queue must be a safe no-op.
    func testFreshStoreIsEmptyAndDrainIsNoOp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-coldstart-\(UUID().uuidString)", isDirectory: true)
        let store = FileWatchMutationStore(directory: dir, namespace: "newuser")

        XCTAssertEqual(store.load(), .empty, "A never-written store reads as empty")

        let applier = FakeWatchApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier)
        let initialPending = await reconciler.pendingCount
        XCTAssertEqual(initialPending, 0)

        await reconciler.drain() // must not crash on empty state
        let afterPending = await reconciler.pendingCount
        XCTAssertEqual(afterPending, 0)
        XCTAssertTrue(applier.playedWrites.isEmpty)
    }

    /// A new user's very first watch must enqueue and converge end-to-end.
    func testFirstEverWatchEnqueuesAndConverges() async throws {
        let store = InMemoryWatchMutationStore()
        let applier = FakeWatchApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        await reconciler.enqueue(playedMutation(capturedAt: Date(), targets: [target("jellyfin", "j1")]))
        await reconciler.drain()

        XCTAssertEqual(applier.playedWrites, [.init(played: true, accountID: "jellyfin", itemID: "j1")])
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 0, "A fully-applied first watch is pruned")
    }
}

// MARK: - Durability across relaunch (offline write survives, no rewind)

final class WatchOutboxDurabilityTests: XCTestCase {
    private func makeStoreDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-outbox-\(UUID().uuidString)", isDirectory: true)
    }

    /// An offline write must survive an app relaunch: the intent is persisted before
    /// the (failing) network call, reloaded from disk by a fresh reconciler, and then
    /// applied once the server is reachable — never silently dropped.
    func testOfflineWriteSurvivesRelaunchThenConverges() async throws {
        let dir = makeStoreDir()
        let ns = "prof"

        // Session 1: enqueue while the server is unreachable; drain fails to apply.
        let applier1 = FakeWatchApplier()
        applier1.failingAccounts = ["plex"]
        do {
            let store1 = FileWatchMutationStore(directory: dir, namespace: ns)
            let reconciler1 = WatchStateReconciler(store: store1, applier: applier1)
            await reconciler1.enqueue(playedMutation(capturedAt: Date(), targets: [target("plex", "p1")]))
            await reconciler1.drain()
            let pending1 = await reconciler1.pendingCount
            XCTAssertEqual(pending1, 1, "A failed write stays queued")
            XCTAssertTrue(applier1.playedWrites.isEmpty)
        }

        // Session 2 ("relaunch"): a brand-new reconciler reads the persisted intent.
        let applier2 = FakeWatchApplier() // server now reachable
        let store2 = FileWatchMutationStore(directory: dir, namespace: ns)
        let reconciler2 = WatchStateReconciler(store: store2, applier: applier2)
        let reloaded = await reconciler2.pendingCount
        XCTAssertEqual(reloaded, 1, "Intent reloaded from disk")

        await reconciler2.drain()
        XCTAssertEqual(applier2.playedWrites, [.init(played: true, accountID: "plex", itemID: "p1")])
        let converged = await reconciler2.pendingCount
        XCTAssertEqual(converged, 0, "Converged on relaunch, then pruned")
    }

    /// "Fail toward writing": if one of two servers is down, the reachable one
    /// converges immediately and the unreachable target stays queued (the watch is
    /// never dropped), then lands on the next drain.
    func testPartialFanOutKeepsOnlyTheFailedTarget() async throws {
        let store = InMemoryWatchMutationStore()
        let applier = FakeWatchApplier()
        applier.failingAccounts = ["plex"]
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        await reconciler.enqueue(playedMutation(capturedAt: Date(), targets: [target("jellyfin", "j1"), target("plex", "p1")]))
        await reconciler.drain()

        XCTAssertEqual(applier.playedWrites, [.init(played: true, accountID: "jellyfin", itemID: "j1")])
        let pendingAfterFail = await reconciler.pendingCount
        XCTAssertEqual(pendingAfterFail, 1, "Only the unreachable server stays queued")

        applier.failingAccounts = []
        await reconciler.drain()
        let pendingAfterRetry = await reconciler.pendingCount
        XCTAssertEqual(pendingAfterRetry, 0)
        XCTAssertEqual(applier.playedWrites.last, .init(played: true, accountID: "plex", itemID: "p1"))
    }
}

// MARK: - Stale-write suppression

final class WatchOutboxStaleWriteTests: XCTestCase {
    /// A late offline write (older `capturedAt`) for a title that already has a newer
    /// accepted action must be DROPPED so it can't rewind state.
    func testOlderWriteAfterNewerAcceptedIsDropped() async throws {
        let store = InMemoryWatchMutationStore()
        let applier = FakeWatchApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)

        // Newer action accepted first.
        let acceptedNewer = await reconciler.enqueue(playedMutation(canonical: "imdb:tt9", played: true, capturedAt: t2, targets: [target("a", "x")]))
        XCTAssertTrue(acceptedNewer)
        // A late, older write for the same title — must be suppressed.
        let acceptedOlder = await reconciler.enqueue(playedMutation(canonical: "imdb:tt9", played: false, capturedAt: t1, targets: [target("a", "x")]))
        XCTAssertFalse(acceptedOlder)

        await reconciler.drain()
        XCTAssertEqual(applier.playedWrites, [.init(played: true, accountID: "a", itemID: "x")],
                       "Only the newer action is applied; the stale one never rewinds it")
    }

    /// A newer action for a title that already had an older queued write supersedes
    /// it (latest-wins), so the older value is never written.
    func testNewerWriteSupersedesOlderQueued() async throws {
        let store = InMemoryWatchMutationStore()
        let applier = FakeWatchApplier()
        applier.failingAccounts = ["a"] // keep the first one queued
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)

        await reconciler.enqueue(playedMutation(canonical: "imdb:tt9", played: false, capturedAt: t1, targets: [target("a", "x")]))
        await reconciler.enqueue(playedMutation(canonical: "imdb:tt9", played: true, capturedAt: t2, targets: [target("a", "x")]))
        let coalesced = await reconciler.pendingCount
        XCTAssertEqual(coalesced, 1, "Same title coalesces to one entry")

        applier.failingAccounts = []
        await reconciler.drain()
        XCTAssertEqual(applier.playedWrites, [.init(played: true, accountID: "a", itemID: "x")],
                       "The newer played=true wins; played=false is never written")
    }
}

// MARK: - Trakt mirror idempotency

final class WatchOutboxTraktTests: XCTestCase {
    private func intent() -> TraktScrobbleIntent {
        TraktScrobbleIntent(kind: .movie, title: "Dune", year: 2021, seasonNumber: nil, episodeNumber: nil, providerIDs: ["imdb": "tt1160419"], progress: 100)
    }

    /// Trakt is mirrored exactly once even across repeated drains (idempotency
    /// ledger), and a finished watch still scrobbles.
    func testTraktMirroredOnceAcrossDrains() async throws {
        let store = InMemoryWatchMutationStore()
        let applier = FakeWatchApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        await reconciler.enqueue(playedMutation(capturedAt: Date(), targets: [target("jellyfin", "j1")], trakt: intent()))
        await reconciler.drain()
        await reconciler.drain() // a second foreground drain must not double-post

        XCTAssertEqual(applier.traktScrobbles.count, 1)
    }

    /// A Trakt failure keeps the mirror pending (server target may already be done)
    /// so it retries — never silently dropped.
    func testTraktFailureRetriesWithoutDroppingServerWrite() async throws {
        let store = InMemoryWatchMutationStore()
        let applier = FakeWatchApplier()
        applier.traktFails = true
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        await reconciler.enqueue(playedMutation(capturedAt: Date(), targets: [target("jellyfin", "j1")], trakt: intent()))
        await reconciler.drain()
        XCTAssertEqual(applier.playedWrites.count, 1, "Server write succeeded")
        let pendingTrakt = await reconciler.pendingCount
        XCTAssertEqual(pendingTrakt, 1, "Trakt mirror still pending")

        applier.traktFails = false
        await reconciler.drain()
        XCTAssertEqual(applier.traktScrobbles.count, 1)
        let done = await reconciler.pendingCount
        XCTAssertEqual(done, 0)
    }
}

// MARK: - Live-session guard (never clobber the now-playing session)

/// The bug these tests pin: a convergence drain that lands on the exact
/// `(account,item)` currently streaming in-app must NOT write to that server
/// while it plays (an out-of-band write — even a session-less one — could race
/// the live now-playing session). The reconciler defers such a target until the
/// live session ends, then converges it. Deferral is never a drop.
final class WatchOutboxLiveSessionTests: XCTestCase {
    private func resumeMutation(capturedAt: Date, targets: [WatchMutationTarget]) -> WatchMutation {
        WatchMutation(
            capturedAt: capturedAt,
            canonicalMediaID: "imdb:tt1",
            resumePosition: 120,
            targets: targets
        )
    }

    /// A drain while item X is the live-playing session emits NO write to X; the
    /// mutation stays queued (deferred, not dropped) and converges once the live
    /// session ends.
    func testDrainDuringLiveSessionDefersWriteToThatItemThenConverges() async throws {
        let store = InMemoryWatchMutationStore()
        let applier = FakeWatchApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        // X is the server currently streaming in-app.
        await reconciler.beginLiveSession(accountID: "jellyfin", itemID: "j1")
        await reconciler.enqueue(resumeMutation(capturedAt: Date(), targets: [target("jellyfin", "j1")]))
        await reconciler.drain()

        XCTAssertTrue(applier.resumeWrites.isEmpty, "No write may land on the live-playing item")
        XCTAssertTrue(applier.playedWrites.isEmpty)
        let deferred = await reconciler.pendingCount
        XCTAssertEqual(deferred, 1, "The write is deferred, not dropped")

        // Playback ends → the deferred write converges.
        await reconciler.endLiveSession(accountID: "jellyfin", itemID: "j1")
        XCTAssertEqual(
            applier.resumeWrites,
            [.init(seconds: 120, accountID: "jellyfin", itemID: "j1")],
            "The deferred write converges once the live session ends"
        )
        let done = await reconciler.pendingCount
        XCTAssertEqual(done, 0)
    }

    /// A drain during a live session still converges the OTHER servers holding the
    /// title immediately — only the live server is deferred. This is the real
    /// cross-server case: keep converging Plex while Jellyfin is the live stream.
    func testDrainDuringLiveSessionStillConvergesOtherServers() async throws {
        let store = InMemoryWatchMutationStore()
        let applier = FakeWatchApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        await reconciler.beginLiveSession(accountID: "jellyfin", itemID: "j1")
        await reconciler.enqueue(resumeMutation(
            capturedAt: Date(),
            targets: [target("jellyfin", "j1"), target("plex", "p1")]
        ))
        await reconciler.drain()

        XCTAssertEqual(
            applier.resumeWrites,
            [.init(seconds: 120, accountID: "plex", itemID: "p1")],
            "The non-live server converges immediately"
        )
        XCTAssertFalse(
            applier.resumeWrites.contains(.init(seconds: 120, accountID: "jellyfin", itemID: "j1")),
            "The live server is never written while playing"
        )
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 1, "The live target is still queued")

        await reconciler.endLiveSession(accountID: "jellyfin", itemID: "j1")
        XCTAssertTrue(applier.resumeWrites.contains(.init(seconds: 120, accountID: "jellyfin", itemID: "j1")))
        let done = await reconciler.pendingCount
        XCTAssertEqual(done, 0)
    }

    /// The guard is item-scoped: a live session for one item never defers writes
    /// for a *different* item on the same account.
    func testLiveSessionGuardIsScopedToTheExactItem() async throws {
        let store = InMemoryWatchMutationStore()
        let applier = FakeWatchApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        await reconciler.beginLiveSession(accountID: "jellyfin", itemID: "j1")
        await reconciler.enqueue(resumeMutation(capturedAt: Date(), targets: [target("jellyfin", "j2")]))
        await reconciler.drain()

        XCTAssertEqual(
            applier.resumeWrites,
            [.init(seconds: 120, accountID: "jellyfin", itemID: "j2")],
            "A different item on the same account is unaffected"
        )
        let done = await reconciler.pendingCount
        XCTAssertEqual(done, 0)
    }
}
