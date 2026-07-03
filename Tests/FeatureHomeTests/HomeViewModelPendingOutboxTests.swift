import XCTest
@testable import CoreModels
@testable import FeatureHome

/// Verifies that `HomeViewModel.reconcileContinueWatching` overlays the durable
/// watch-outbox's not-yet-confirmed plays onto a freshly-fetched Continue Watching
/// row, so a reload reflects what the user just played in-app before every server's
/// Resume/OnDeck query catches up — the fix for the reported "Continue Watching
/// keeps shifting / isn't what I watched last" symptom (r8-cw-outbox-patch).
final class HomeViewModelPendingOutboxTests: XCTestCase {

    private func cwItem(
        id: String,
        account: String,
        lastPlayedAt: Date?,
        resume: TimeInterval? = nil
    ) -> MediaItem {
        var item = MediaItem(id: id, title: "Title-\(id)", kind: .movie)
        item.sourceAccountID = account
        item.lastPlayedAt = lastPlayedAt
        item.resumePosition = resume
        item.sources = [
            MediaSourceRef(accountID: account, itemID: id, resumePosition: resume, lastPlayedAt: lastPlayedAt)
        ]
        return item
    }

    private func mutation(
        account: String,
        itemID: String,
        capturedAt: Date,
        resume: TimeInterval? = nil,
        played: Bool? = nil,
        clearResume: Bool = false
    ) -> WatchMutation {
        WatchMutation(
            capturedAt: capturedAt,
            canonicalMediaID: "local:\(itemID)",
            resumePosition: resume,
            played: played,
            clearResume: clearResume,
            targets: [WatchMutationTarget(accountID: account, itemID: itemID)]
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let t2 = Date(timeIntervalSince1970: 3_000)

    func testEmptyPendingLeavesRowUnchanged() {
        let items = [
            cwItem(id: "a", account: "p", lastPlayedAt: t1),
            cwItem(id: "b", account: "p", lastPlayedAt: t0)
        ]
        XCTAssertEqual(
            HomeViewModel.reconcileContinueWatching(items, pending: []).map(\.id),
            ["a", "b"],
            "With no pending writes the fetched row is returned untouched"
        )
    }

    func testInProgressPlayFloatsTitleToFrontWithFreshRecency() {
        // Server feed has B most-recent; but the user just resumed A in-app (newer
        // than the server knows). The overlay must stamp A with the play's recency
        // and re-sort it to the front.
        let items = [
            cwItem(id: "b", account: "p", lastPlayedAt: t1),
            cwItem(id: "a", account: "p", lastPlayedAt: t0, resume: 10)
        ]
        let pending = [mutation(account: "p", itemID: "a", capturedAt: t2, resume: 900)]

        let result = HomeViewModel.reconcileContinueWatching(items, pending: pending)
        XCTAssertEqual(result.map(\.id), ["a", "b"], "The just-resumed title floats to the front")

        let a = try! XCTUnwrap(result.first { $0.id == "a" })
        XCTAssertEqual(a.lastPlayedAt, t2, "Recency is stamped from the pending play's capturedAt")
        XCTAssertEqual(a.resumePosition, 900, "Resume position reflects the in-flight write")
        XCTAssertEqual(a.sources.first?.lastPlayedAt, t2, "Matching source ref is stamped too")
        XCTAssertEqual(a.sources.first?.resumePosition, 900)
    }

    func testFinishedPlayDropsTitleFromRow() {
        // The user finished A in-app; the server hasn't removed it from Resume yet.
        // A `played == true` pending write must drop it, anticipating that removal.
        let items = [
            cwItem(id: "a", account: "p", lastPlayedAt: t0, resume: 500),
            cwItem(id: "b", account: "p", lastPlayedAt: t1)
        ]
        let pending = [mutation(account: "p", itemID: "a", capturedAt: t2, resume: 0, played: true, clearResume: true)]

        let result = HomeViewModel.reconcileContinueWatching(items, pending: pending)
        XCTAssertEqual(result.map(\.id), ["b"], "A finished title leaves Continue Watching")
    }

    func testSupersededPendingWriteIsIgnored() {
        // The server feed already reflects a play NEWER than the queued write (the
        // outbox entry is stale/about-to-be-dropped). It must not reorder anything.
        let items = [
            cwItem(id: "a", account: "p", lastPlayedAt: t2, resume: 900),
            cwItem(id: "b", account: "p", lastPlayedAt: t1)
        ]
        let pending = [mutation(account: "p", itemID: "a", capturedAt: t0, resume: 100)]

        let result = HomeViewModel.reconcileContinueWatching(items, pending: pending)
        XCTAssertEqual(result.map(\.id), ["a", "b"], "Order unchanged")
        let a = try! XCTUnwrap(result.first { $0.id == "a" })
        XCTAssertEqual(a.lastPlayedAt, t2, "A superseded write must not rewind recency")
        XCTAssertEqual(a.resumePosition, 900, "A superseded write must not rewind resume")
    }

    func testMarkUnwatchedNeitherReordersNorDrops() {
        // A bare mark-unwatched (played == false, no resume) is not a "recently
        // watched" event: it must neither float the card nor remove it.
        let items = [
            cwItem(id: "a", account: "p", lastPlayedAt: t0),
            cwItem(id: "b", account: "p", lastPlayedAt: t1)
        ]
        let pending = [mutation(account: "p", itemID: "a", capturedAt: t2, played: false)]

        let result = HomeViewModel.reconcileContinueWatching(items, pending: pending)
        XCTAssertEqual(result.map(\.id), ["b", "a"], "Non-play mutation leaves the server order intact")
    }

    func testMatchesMergedCardViaAnySourceRef() {
        // A cross-server merged card lists several servers; a pending write that
        // targets a *secondary* source (the server the user actually played from)
        // must still match the card by that source ref.
        var merged = MediaItem(id: "primary", title: "Dune", kind: .movie)
        merged.sourceAccountID = "plex"
        merged.lastPlayedAt = t0
        merged.sources = [
            MediaSourceRef(accountID: "plex", itemID: "primary", lastPlayedAt: t0),
            MediaSourceRef(accountID: "jelly", itemID: "jf-id", lastPlayedAt: t0)
        ]
        let other = cwItem(id: "other", account: "plex", lastPlayedAt: t1)
        let pending = [mutation(account: "jelly", itemID: "jf-id", capturedAt: t2, resume: 1200)]

        let result = HomeViewModel.reconcileContinueWatching([other, merged], pending: pending)
        XCTAssertEqual(result.map(\.id), ["primary", "other"], "Merged card floats via its Jellyfin source")
        let dune = try! XCTUnwrap(result.first { $0.id == "primary" })
        XCTAssertEqual(dune.lastPlayedAt, t2)
        // Only the played (jelly) source ref is stamped; the plex ref is untouched.
        XCTAssertEqual(dune.sources.first { $0.accountID == "jelly" }?.lastPlayedAt, t2)
        XCTAssertEqual(dune.sources.first { $0.accountID == "jelly" }?.resumePosition, 1200)
        XCTAssertEqual(dune.sources.first { $0.accountID == "plex" }?.lastPlayedAt, t0)
    }

    // MARK: - Drain-time inflation clamp (h2-cw-clamp)

    /// A fresh applied-resume record clamps a Plex source's inflated (drain-time)
    /// `lastPlayedAt` back down to the real play time, so a stale title that a late
    /// offline drain re-floated drops back below a genuinely-newer one. Pending is
    /// empty on purpose: by the reload that shows the bug the write has drained+pruned.
    func testFreshRecencyClampsInflatedPlexSourceDownAndReorders() {
        let items = [
            cwItem(id: "a", account: "plex", lastPlayedAt: t2, resume: 900), // inflated to drain time
            cwItem(id: "b", account: "plex", lastPlayedAt: t1)               // genuinely newer than real play
        ]
        let recency = ["plex:a": AppliedResumeRecord(capturedAt: t0, appliedAt: t2)]

        let result = HomeViewModel.reconcileContinueWatching(
            items, pending: [], appliedRecency: recency, now: t2, clampFreshness: 60
        )
        XCTAssertEqual(result.map(\.id), ["b", "a"], "The re-floated title drops back below the genuinely-newer one")
        let a = try! XCTUnwrap(result.first { $0.id == "a" })
        XCTAssertEqual(a.lastPlayedAt, t0, "Recency is clamped down to the real play time")
        XCTAssertEqual(a.sources.first?.lastPlayedAt, t0, "The source ref is clamped too")
    }

    /// A stale record (older than the freshness window) must NOT clamp: the server's
    /// newer timestamp is treated as a genuine later play (e.g. on another client),
    /// so it stays on top. This is the guard that keeps the clamp from misfiring.
    func testStaleRecencyDoesNotClampGenuineLaterPlay() {
        let items = [
            cwItem(id: "a", account: "plex", lastPlayedAt: t2, resume: 900),
            cwItem(id: "b", account: "plex", lastPlayedAt: t1)
        ]
        // appliedAt = t0; now = t0 + 61 with a 60s window ⇒ record is stale.
        let recency = ["plex:a": AppliedResumeRecord(capturedAt: t0, appliedAt: t0)]

        let result = HomeViewModel.reconcileContinueWatching(
            items, pending: [], appliedRecency: recency,
            now: t0.addingTimeInterval(61), clampFreshness: 60
        )
        XCTAssertEqual(result.map(\.id), ["a", "b"], "A stale record leaves a genuine later play on top")
        let a = try! XCTUnwrap(result.first { $0.id == "a" })
        XCTAssertEqual(a.lastPlayedAt, t2, "A stale record must not rewind a genuine later play")
    }

    /// Downward-only: the clamp never *raises* a server's timestamp, even when our
    /// recorded play is newer than what the server reports.
    func testClampNeverRaisesRecency() {
        let items = [cwItem(id: "a", account: "plex", lastPlayedAt: t0, resume: 900)]
        let recency = ["plex:a": AppliedResumeRecord(capturedAt: t1, appliedAt: t1)] // capturedAt newer than reported

        let result = HomeViewModel.reconcileContinueWatching(
            items, pending: [], appliedRecency: recency, now: t1, clampFreshness: 60
        )
        let a = try! XCTUnwrap(result.first { $0.id == "a" })
        XCTAssertEqual(a.lastPlayedAt, t0, "The clamp is strictly downward — it never raises recency")
    }

    /// A Jellyfin-style source (server honored `capturedAt`, so reported == real play)
    /// is a no-op: nothing to clamp.
    func testClampIsNoOpWhenServerHonoredCapturedAt() {
        let items = [
            cwItem(id: "a", account: "jelly", lastPlayedAt: t0, resume: 900),
            cwItem(id: "b", account: "jelly", lastPlayedAt: t1)
        ]
        let recency = ["jelly:a": AppliedResumeRecord(capturedAt: t0, appliedAt: t1)]

        let result = HomeViewModel.reconcileContinueWatching(
            items, pending: [], appliedRecency: recency, now: t1, clampFreshness: 60
        )
        XCTAssertEqual(result.map(\.id), ["b", "a"], "Order reflects the untouched server recency")
        let a = try! XCTUnwrap(result.first { $0.id == "a" })
        XCTAssertEqual(a.lastPlayedAt, t0, "No inflation to undo ⇒ no change")
    }

    /// On a cross-server merged card, only the inflated (Plex) source is clamped; the
    /// card's folded recency drops to the remaining source, re-sorting the card down.
    func testClampOnMergedCardRefoldsAcrossSources() {
        var merged = MediaItem(id: "primary", title: "Dune", kind: .movie)
        merged.sourceAccountID = "plex"
        merged.lastPlayedAt = t2 // folded from the inflated Plex source
        merged.resumePosition = 900
        merged.sources = [
            MediaSourceRef(accountID: "plex", itemID: "primary", resumePosition: 900, lastPlayedAt: t2),
            MediaSourceRef(accountID: "jelly", itemID: "jf-id", lastPlayedAt: t0)
        ]
        let other = cwItem(id: "other", account: "plex", lastPlayedAt: t1)
        let recency = ["plex:primary": AppliedResumeRecord(capturedAt: t0, appliedAt: t2)]

        let result = HomeViewModel.reconcileContinueWatching(
            [merged, other], pending: [], appliedRecency: recency, now: t2, clampFreshness: 60
        )
        XCTAssertEqual(result.map(\.id), ["other", "primary"], "The de-inflated merged card sorts below the newer one")
        let dune = try! XCTUnwrap(result.first { $0.id == "primary" })
        XCTAssertEqual(dune.lastPlayedAt, t0, "Card recency re-folds down to the clamped source")
        XCTAssertEqual(dune.sources.first { $0.accountID == "plex" }?.lastPlayedAt, t0, "Only the Plex source is clamped")
        XCTAssertEqual(dune.sources.first { $0.accountID == "jelly" }?.lastPlayedAt, t0, "The Jellyfin source is untouched")
    }
}
