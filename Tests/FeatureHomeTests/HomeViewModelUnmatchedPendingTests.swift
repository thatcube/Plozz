import XCTest
@testable import CoreModels
@testable import FeatureHome

/// Pins down the one thing `reconcileContinueWatching` cannot do, and the helper
/// that makes it visible.
///
/// The overlay exists to stop a reload reverting Continue Watching to pre-play
/// order while a server catches up. It can drop a card and it can restamp one —
/// but it will not fabricate a card the feed did not return, and that is the
/// correct call: inventing rows from local state is how a client starts showing
/// titles the server has no idea about.
///
/// The cost of that correctness is a real gap. A title the viewer just started
/// which the server has not yet listed has nowhere to be placed, so it simply
/// does not appear — and nothing in the load path treats that as noteworthy.
/// Reaching a title from Search is the everyday way to land here, because a
/// title found by searching is by definition one that was not already on the row.
/// These tests fix that behaviour in place and prove the helper names it.
final class HomeViewModelUnmatchedPendingTests: XCTestCase {

    private func cwItem(id: String, account: String, lastPlayedAt: Date?) -> MediaItem {
        var item = MediaItem(id: id, title: "Title-\(id)", kind: .movie)
        item.sourceAccountID = account
        item.lastPlayedAt = lastPlayedAt
        item.sources = [MediaSourceRef(accountID: account, itemID: id, lastPlayedAt: lastPlayedAt)]
        return item
    }

    private func mutation(
        account: String,
        itemID: String,
        capturedAt: Date,
        resume: TimeInterval? = nil,
        played: Bool? = nil
    ) -> WatchMutation {
        WatchMutation(
            capturedAt: capturedAt,
            canonicalMediaID: "local:\(itemID)",
            resumePosition: resume,
            played: played,
            targets: [WatchMutationTarget(accountID: account, itemID: itemID)]
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    /// The reported symptom, reduced: play something the row has never carried,
    /// and reloading Home does not surface it — the overlay holds the play but has
    /// no card to attach it to.
    func testFreshPlayForATitleTheFeedOmittedNeverReachesTheRow() {
        let fetched = [cwItem(id: "already-on-row", account: "plex", lastPlayedAt: t0)]
        let pending = [mutation(account: "plex", itemID: "just-started-from-search", capturedAt: t1, resume: 300)]

        let reconciled = HomeViewModel.reconcileContinueWatching(fetched, pending: pending)

        XCTAssertEqual(
            reconciled.map(\.id),
            ["already-on-row"],
            "The overlay never invents a card, so a just-started title the server has not listed yet stays invisible"
        )
    }

    /// The same play, named. This is what turns "nothing appeared" into a
    /// reportable observation in the device log.
    func testUnmatchedHelperNamesThePlayTheRowCouldNotShow() {
        let fetched = [cwItem(id: "already-on-row", account: "plex", lastPlayedAt: t0)]
        let pending = [mutation(account: "plex", itemID: "just-started-from-search", capturedAt: t1, resume: 300)]

        XCTAssertEqual(
            HomeViewModel.unmatchedPendingTargets(in: fetched, pending: pending),
            ["plex:just-started-from-search"]
        )
    }

    /// A play the feed already covers is not a gap — the overlay restamps it in
    /// place, which is exactly what it is for.
    func testPlayThatMatchesAFetchedCardIsNotReportedAsAGap() {
        let fetched = [cwItem(id: "a", account: "plex", lastPlayedAt: t0)]
        let pending = [mutation(account: "plex", itemID: "a", capturedAt: t1, resume: 300)]

        XCTAssertTrue(HomeViewModel.unmatchedPendingTargets(in: fetched, pending: pending).isEmpty)
    }

    /// A *finished* play is supposed to be missing from Continue Watching, so its
    /// absence is the intended outcome rather than something to flag.
    func testFinishedPlayAbsentFromTheFeedIsNotAGap() {
        let fetched = [cwItem(id: "a", account: "plex", lastPlayedAt: t0)]
        let pending = [mutation(account: "plex", itemID: "finished", capturedAt: t1, played: true)]

        XCTAssertTrue(HomeViewModel.unmatchedPendingTargets(in: fetched, pending: pending).isEmpty)
    }

    /// Cards are matched on their source refs too, not just the card's own id, so
    /// a cross-server merged card covers the play on any of its servers.
    func testMatchesAgainstEverySourceRefOnAMergedCard() {
        var merged = MediaItem(id: "jf-1", title: "Merged", kind: .movie)
        merged.sourceAccountID = "jellyfin"
        merged.sources = [
            MediaSourceRef(accountID: "jellyfin", itemID: "jf-1"),
            MediaSourceRef(accountID: "plex", itemID: "px-1")
        ]

        let pending = [mutation(account: "plex", itemID: "px-1", capturedAt: t1, resume: 120)]

        XCTAssertTrue(
            HomeViewModel.unmatchedPendingTargets(in: [merged], pending: pending).isEmpty,
            "The play landed on a server this merged card already represents"
        )
    }

    func testNoPendingWritesMeansNoGap() {
        let fetched = [cwItem(id: "a", account: "plex", lastPlayedAt: t0)]
        XCTAssertTrue(HomeViewModel.unmatchedPendingTargets(in: fetched, pending: []).isEmpty)
    }
}

/// Guards the reading the feed diagnostics apply to a row, since the whole point
/// of the telemetry is to separate "the server said so" from "we got it wrong".
final class ContinueWatchingDiagnosticsRowTests: XCTestCase {

    func testWatchedWithNoResumeOffsetIsFlaggedAsSuspect() {
        let row = ContinueWatchingDiagnostics.ServerRow(
            id: "1", kind: "movie", title: "Finished", viewOffsetMS: 0, durationMS: 7_200_000, viewCount: 1
        )
        XCTAssertTrue(
            row.looksAlreadyWatched,
            "A title the server counts as watched, with no resume point, should not be in a resume feed"
        )
    }

    func testResumePointAtTheVeryEndIsFlaggedAsSuspect() {
        let row = ContinueWatchingDiagnostics.ServerRow(
            id: "2", kind: "episode", title: "Credits", viewOffsetMS: 6_960_000, durationMS: 7_200_000, viewCount: 0
        )
        XCTAssertTrue(row.looksAlreadyWatched, "A resume point sitting in the credits is a finish the server never recorded")
    }

    func testGenuineMidwayResumeIsNotSuspect() {
        let row = ContinueWatchingDiagnostics.ServerRow(
            id: "3", kind: "movie", title: "Halfway", viewOffsetMS: 3_600_000, durationMS: 7_200_000, viewCount: 0
        )
        XCTAssertFalse(row.looksAlreadyWatched)
    }

    /// A next-episode suggestion has no offset and no watch count. It belongs in
    /// the feed and must not be mistaken for a stale entry.
    func testNextUpSuggestionIsNotSuspect() {
        let row = ContinueWatchingDiagnostics.ServerRow(
            id: "4", kind: "episode", title: "Next up", viewOffsetMS: nil, durationMS: 7_200_000, viewCount: 0
        )
        XCTAssertFalse(row.looksAlreadyWatched)
    }

    func testFeedLineCountsSuspectRows() {
        let line = ContinueWatchingDiagnostics.serverFeedLine(
            provider: "plex",
            accountID: "acct",
            endpoint: "/library/onDeck",
            rows: [
                .init(id: "1", kind: "movie", title: "Finished", viewOffsetMS: 0, durationMS: 100, viewCount: 1),
                .init(id: "2", kind: "movie", title: "Halfway", viewOffsetMS: 50, durationMS: 100, viewCount: 0)
            ]
        )
        XCTAssertTrue(line.contains("rows=2"))
        XCTAssertTrue(line.contains("suspect=1"))
        XCTAssertTrue(line.contains("<<SUSPECT-ALREADY-WATCHED"))
    }

    func testOverlayLineCallsOutAPlayWithNoCard() {
        let line = ContinueWatchingDiagnostics.overlayLine(
            fetched: 5, reconciled: 5, pending: 1, unmatched: ["plex:99"]
        )
        XCTAssertTrue(line.contains("<<PENDING-PLAY-WITH-NO-CARD"))
        XCTAssertTrue(line.contains("plex:99"))
    }

    func testHomeMutationLineCallsOutADroppedPlay() {
        let dropped = ContinueWatchingDiagnostics.homeMutationLine(
            played: nil, resumePosition: 300, onRow: false, reloadScheduled: false, state: "loading"
        )
        XCTAssertTrue(dropped.contains("<<DROPPED-NO-ROW-UPDATE"))

        let handled = ContinueWatchingDiagnostics.homeMutationLine(
            played: nil, resumePosition: 300, onRow: false, reloadScheduled: true, state: "loaded"
        )
        XCTAssertFalse(handled.contains("<<DROPPED-NO-ROW-UPDATE"))
    }
}

/// Covers the feed-versus-hub diff, which is the only way to see a dismissal.
///
/// A title removed from Continue Watching keeps its resume position and reads as
/// ordinary half-watched content in a resume feed — there is no field that says
/// the viewer dismissed it. Only the hub applies the exclusion, so the difference
/// between the two lists *is* the evidence.
final class ContinueWatchingDiagnosticsDiffTests: XCTestCase {

    private func row(_ id: String, _ title: String, pct: Int = 40) -> ContinueWatchingDiagnostics.ServerRow {
        .init(id: id, kind: "movie", title: title, viewOffsetMS: pct * 100, durationMS: 10_000, viewCount: nil)
    }

    /// The reported symptom: we show it, Plex does not.
    func testTitleInFeedButNotInHubIsFlagged() {
        let line = ContinueWatchingDiagnostics.feedVersusHubLine(
            feed: [row("1", "Kept"), row("2", "Dismissed")],
            hub: [row("1", "Kept")],
            hubEndpoint: "/hubs/home/continueWatching"
        )
        XCTAssertTrue(line.contains("feedOnly=1"))
        XCTAssertTrue(line.contains("FEED-ONLY"))
        XCTAssertTrue(line.contains("<<SHOWN-BY-US-BUT-NOT-BY-PLEX"))
        XCTAssertTrue(line.contains("Dismissed"))
    }

    /// A dismissed title is mid-progress and otherwise unremarkable — proving the
    /// diff catches what the per-row heuristic cannot.
    func testDismissedTitleIsNotOtherwiseSuspicious() {
        let dismissed = row("2", "Dismissed", pct: 40)
        XCTAssertFalse(
            dismissed.looksAlreadyWatched,
            "Nothing about the row itself betrays the dismissal; only the diff can"
        )
        XCTAssertTrue(
            ContinueWatchingDiagnostics
                .feedVersusHubLine(feed: [dismissed], hub: [], hubEndpoint: "/hubs/home/continueWatching")
                .contains("<<SHOWN-BY-US-BUT-NOT-BY-PLEX")
        )
    }

    func testAgreeingListsProduceNoFindings() {
        let line = ContinueWatchingDiagnostics.feedVersusHubLine(
            feed: [row("1", "A"), row("2", "B")],
            hub: [row("2", "B"), row("1", "A")],
            hubEndpoint: "/hubs/home/continueWatching"
        )
        XCTAssertTrue(line.contains("feedOnly=0"))
        XCTAssertTrue(line.contains("hubOnly=0"))
        XCTAssertFalse(line.contains("<<"), "Order alone is not a disagreement")
    }

    /// The mirror case — Plex offers something we never show.
    func testTitleInHubButNotInFeedIsReportedSeparately() {
        let line = ContinueWatchingDiagnostics.feedVersusHubLine(
            feed: [],
            hub: [row("9", "Missing from our row")],
            hubEndpoint: "/hubs/home/continueWatching"
        )
        XCTAssertTrue(line.contains("hubOnly=1"))
        XCTAssertTrue(line.contains("<<PLEX-SHOWS-IT-WE-DO-NOT"))
    }

    /// A failed request must never read as a dismissal — the whole diff is void.
    func testUnavailableHubIsNotReadAsDismissal() {
        let line = ContinueWatchingDiagnostics.feedVersusHubLine(
            feed: [row("1", "A")],
            hub: nil,
            hubEndpoint: "/hubs/continueWatching",
            hubError: "notFound"
        )
        XCTAssertTrue(line.contains("UNAVAILABLE"))
        XCTAssertTrue(line.contains("<<CANNOT-CONFIRM-DISMISSALS"))
        XCTAssertFalse(
            line.contains("<<SHOWN-BY-US-BUT-NOT-BY-PLEX"),
            "A hub we could not reach proves nothing about any title"
        )
    }
}
