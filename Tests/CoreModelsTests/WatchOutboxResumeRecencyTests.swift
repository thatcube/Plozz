import XCTest
@testable import CoreModels

/// Verifies the reconciler records — and prunes — the ``AppliedResumeRecord`` for an
/// in-progress resume write it applies, so Home's Continue Watching overlay can clamp
/// a server's drain-time timestamp inflation (an offline-drained Plex resume) back
/// down to the play's real time without ever overriding a genuine later play.
/// (h2-cw-clamp)
final class WatchOutboxResumeRecencyTests: XCTestCase {

    private final class FakeApplier: WatchMutationApplying, @unchecked Sendable {
        private let lock = NSLock()
        var failingAccounts: Set<String> = []
        private(set) var resumeWrites: [(TimeInterval, String)] = []

        func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
            if failingAccounts.contains(target.accountID) { throw AppError.serverUnreachable }
        }
        func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
            if failingAccounts.contains(target.accountID) { throw AppError.serverUnreachable }
            lock.lock(); resumeWrites.append((seconds, target.id)); lock.unlock()
        }
        func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {}
    }

    private func target(_ account: String, _ item: String) -> WatchMutationTarget {
        WatchMutationTarget(accountID: account, itemID: item)
    }

    private func resume(_ seconds: TimeInterval, capturedAt: Date, canonical: String = "imdb:tt1", targets: [WatchMutationTarget]) -> WatchMutation {
        WatchMutation(capturedAt: capturedAt, canonicalMediaID: canonical, resumePosition: seconds, targets: targets)
    }

    private func finish(capturedAt: Date, canonical: String = "imdb:tt1", targets: [WatchMutationTarget]) -> WatchMutation {
        WatchMutation(capturedAt: capturedAt, canonicalMediaID: canonical, played: true, clearResume: true, targets: targets)
    }

    private let playTime = Date(timeIntervalSince1970: 1_000)   // when the user actually watched
    private let drainTime = Date(timeIntervalSince1970: 9_000)  // much later (server was offline)

    /// An applied in-progress resume records `{capturedAt: playTime, appliedAt: now}`
    /// keyed by target, so the overlay knows the true play time despite the server
    /// stamping its own (drain) clock.
    func testInProgressResumeRecordsAppliedRecency() async {
        let store = InMemoryWatchMutationStore()
        let applier = FakeApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier, now: { self.drainTime })

        await reconciler.enqueue(resume(900, capturedAt: playTime, targets: [target("plex", "rk1")]))
        await reconciler.drain()

        let record = await reconciler.snapshot().appliedRecency["plex:rk1"]
        XCTAssertEqual(record?.capturedAt, playTime, "The play's real time is recorded, not the drain clock")
        XCTAssertEqual(record?.appliedAt, drainTime, "appliedAt is when we actually wrote (device clock)")
    }

    /// A finish (played + clearResume) removes any recency record — the title leaves
    /// Continue Watching, so there is nothing left to clamp.
    func testFinishClearsAppliedRecency() async {
        let store = InMemoryWatchMutationStore()
        let applier = FakeApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier, now: { self.drainTime })

        await reconciler.enqueue(resume(900, capturedAt: playTime, targets: [target("plex", "rk1")]))
        await reconciler.drain()
        let recorded = await reconciler.snapshot().appliedRecency["plex:rk1"]
        XCTAssertNotNil(recorded)

        await reconciler.enqueue(finish(capturedAt: playTime.addingTimeInterval(60), targets: [target("plex", "rk1")]))
        await reconciler.drain()
        let cleared = await reconciler.snapshot().appliedRecency["plex:rk1"]
        XCTAssertNil(cleared, "A finish clears the resume record")
    }

    /// A pure finish (no in-progress position) records nothing — recency only guards
    /// resumes that stay in Continue Watching.
    func testFinishOnlyWriteRecordsNoRecency() async {
        let store = InMemoryWatchMutationStore()
        let applier = FakeApplier()
        let reconciler = WatchStateReconciler(store: store, applier: applier, now: { self.drainTime })

        await reconciler.enqueue(finish(capturedAt: playTime, targets: [target("plex", "rk1")]))
        await reconciler.drain()
        let snapshot = await reconciler.snapshot()
        XCTAssertTrue(snapshot.appliedRecency.isEmpty)
    }

    /// The record is short-lived: a later drain past the TTL prunes it, so a stale
    /// record can never override a genuine later play (e.g. one made on another client).
    func testAppliedRecencyPrunedAfterTTL() async {
        final class Clock: @unchecked Sendable { var date: Date; init(_ d: Date) { date = d } }
        let store = InMemoryWatchMutationStore()
        let applier = FakeApplier()
        let clock = Clock(drainTime)
        let reconciler = WatchStateReconciler(
            store: store, applier: applier, now: { clock.date }, resumeRecencyTTL: 60
        )

        await reconciler.enqueue(resume(900, capturedAt: playTime, targets: [target("plex", "rk1")]))
        await reconciler.drain()
        let present = await reconciler.snapshot().appliedRecency["plex:rk1"]
        XCTAssertNotNil(present)

        // A later drain, past the TTL, prunes the stale record.
        clock.date = drainTime.addingTimeInterval(61)
        await reconciler.drain()
        let pruned = await reconciler.snapshot().appliedRecency["plex:rk1"]
        XCTAssertNil(pruned, "A record older than the TTL is pruned")
    }

    /// A newer play supersedes the recorded time (newest-wins), and a target whose
    /// write failed (offline server) records nothing until it actually converges.
    func testNewestWinsAndFailedWriteRecordsNothing() async {
        let store = InMemoryWatchMutationStore()
        let applier = FakeApplier()
        applier.failingAccounts = ["plex"]
        let reconciler = WatchStateReconciler(store: store, applier: applier, now: { self.drainTime })

        // Plex offline: the resume write throws, stays queued, records nothing.
        await reconciler.enqueue(resume(900, capturedAt: playTime, targets: [target("plex", "rk1")]))
        await reconciler.drain()
        let whileOffline = await reconciler.snapshot().appliedRecency["plex:rk1"]
        XCTAssertNil(whileOffline, "A failed write records no recency")

        // Plex back online: the queued write converges and records the play time.
        applier.failingAccounts = []
        await reconciler.drain()
        let afterConverge = await reconciler.snapshot().appliedRecency["plex:rk1"]
        XCTAssertEqual(afterConverge?.capturedAt, playTime)
    }
}
