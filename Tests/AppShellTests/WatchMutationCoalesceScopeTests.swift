import XCTest
import CoreModels
@testable import AppShell

/// Regression tests for the outbox coalesce key's kind- and series-scoping.
///
/// The coalesce key collapses queued watch writes for "the same title" across
/// servers and relaunches. Two failure modes it must NOT fall into:
///  1. A movie and a series that merely share an external integer id (TMDb/TVDb
///     reuse one id space — movie 550 ≠ tv 550) collapsing into one entry and
///     cross-applying watched state.
///  2. Two unrelated shows whose episodes share a generic title ("Pilot",
///     "Episode 1") collapsing because the canonical id fell back to the *episode*
///     title instead of the *series* title.
/// It must still coalesce the genuinely-same episode seen through two servers.
final class WatchMutationCoalesceScopeTests: XCTestCase {
    private func key(_ item: MediaItem) -> String? {
        WatchMutationFactory.playedToggle(
            item: item,
            played: true,
            primaryAccountID: item.sourceAccountID
        )?.coalesceKey
    }

    func testMovieAndSeriesSharingExternalIDDoNotCoalesce() {
        let movie = MediaItem(id: "m1", title: "Work", kind: .movie,
                              productionYear: 2014,
                              providerIDs: ["tmdb": "550"], sourceAccountID: "acct-a")
        let series = MediaItem(id: "s1", title: "Work", kind: .series,
                               productionYear: 2014,
                               providerIDs: ["tmdb": "550"], sourceAccountID: "acct-a")

        let movieKey = key(movie)
        let seriesKey = key(series)
        XCTAssertNotNil(movieKey)
        XCTAssertNotNil(seriesKey)
        XCTAssertNotEqual(
            movieKey, seriesKey,
            "A movie and a series sharing an external integer id must not share a coalesce key"
        )
    }

    func testGenericEpisodeTitlesAcrossDifferentSeriesDoNotCoalesce() {
        // No external ids, so the canonical id falls back to a title slug. Both
        // episodes are "Pilot" S1E1 — only the parent SERIES title distinguishes them.
        let breakingBadPilot = MediaItem(id: "bb-e1", title: "Pilot", kind: .episode,
                                         parentTitle: "Breaking Bad", seasonNumber: 1,
                                         episodeNumber: 1, sourceAccountID: "acct-a")
        let theWirePilot = MediaItem(id: "tw-e1", title: "Pilot", kind: .episode,
                                     parentTitle: "The Wire", seasonNumber: 1,
                                     episodeNumber: 1, sourceAccountID: "acct-a")

        let bbKey = key(breakingBadPilot)
        let twKey = key(theWirePilot)
        XCTAssertNotNil(bbKey)
        XCTAssertNotNil(twKey)
        XCTAssertNotEqual(
            bbKey, twKey,
            "Two different series' identically-titled pilots must not share a coalesce key"
        )
    }

    func testSameEpisodeAcrossTwoServersStillCoalesces() {
        // The genuinely-same episode reached through two different servers (no
        // external ids) must produce ONE coalesce key so the writes collapse.
        let onServerA = MediaItem(id: "server-a-item-99", title: "Pilot", kind: .episode,
                                  parentTitle: "Breaking Bad", seasonNumber: 1,
                                  episodeNumber: 1, sourceAccountID: "acct-a")
        let onServerB = MediaItem(id: "server-b-item-42", title: "Pilot", kind: .episode,
                                  parentTitle: "Breaking Bad", seasonNumber: 1,
                                  episodeNumber: 1, sourceAccountID: "acct-b")

        let keyA = key(onServerA)
        let keyB = key(onServerB)
        XCTAssertNotNil(keyA)
        XCTAssertEqual(
            keyA, keyB,
            "The same episode on two servers must share a coalesce key so the writes coalesce"
        )
    }
}
