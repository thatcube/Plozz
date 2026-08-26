import XCTest
@testable import CoreModels

/// Fixes the rules for what belongs on the Continue Watching row.
///
/// The row is built from feeds that disagree — each backend has its own idea of
/// "resume", and some of them volunteer next-episode suggestions for series the
/// viewer walked away from months ago. These tests pin the one rule that decides,
/// and in particular the asymmetry at its heart: a title that was *started* is a
/// promise to come back and is never retired on age, while a suggestion carries
/// no such promise.
final class ContinueWatchingPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        id: String,
        resume: TimeInterval? = nil,
        lastPlayedDaysAgo: Double? = nil
    ) -> MediaItem {
        var item = MediaItem(id: id, title: "Title-\(id)", kind: .episode)
        item.resumePosition = resume
        item.lastPlayedAt = lastPlayedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        return item
    }

    private var policy: ContinueWatchingPolicy { ContinueWatchingPolicy(nextUpCutoff: 90 * 86_400) }

    // MARK: In-progress titles are never retired

    /// The case that must never regress: something stopped halfway is where the
    /// viewer left off, however long ago. Dropping it loses their place.
    func testAnInProgressTitleSurvivesAnyAge() {
        XCTAssertTrue(policy.keeps(item(id: "a", resume: 1_200, lastPlayedDaysAgo: 3_650), now: now))
    }

    func testAnInProgressTitleWithNoTimestampIsKept() {
        XCTAssertTrue(policy.keeps(item(id: "a", resume: 1_200), now: now))
    }

    // MARK: Suggestions are bounded by the age of the series

    func testARecentSuggestionIsKept() {
        XCTAssertTrue(policy.keeps(item(id: "a", lastPlayedDaysAgo: 10), now: now))
    }

    func testAnAncientSuggestionIsRetired() {
        XCTAssertFalse(policy.keeps(item(id: "a", lastPlayedDaysAgo: 200), now: now))
    }

    /// Exactly at the boundary the title stays. A cutoff should retire what is
    /// past it, not what has just reached it.
    func testTheBoundaryItselfIsInclusive() {
        XCTAssertTrue(policy.keeps(item(id: "a", lastPlayedDaysAgo: 90), now: now))
        XCTAssertFalse(policy.keeps(item(id: "b", lastPlayedDaysAgo: 90.5), now: now))
    }

    // MARK: Fail-open

    /// A missing timestamp is an absence of evidence. Guessing from it would
    /// silently delete titles on any backend that doesn't report recency.
    func testASuggestionWithNoTimestampIsKept() {
        XCTAssertTrue(policy.keeps(item(id: "a"), now: now))
    }

    func testNoCutoffKeepsEverything() {
        let unbounded = ContinueWatchingPolicy(nextUpCutoff: nil)
        XCTAssertTrue(unbounded.keeps(item(id: "a", lastPlayedDaysAgo: 10_000), now: now))
    }

    // MARK: Curation

    func testCurationRetiresOnlyTheStaleSuggestions() {
        let items = [
            item(id: "in-progress-old", resume: 900, lastPlayedDaysAgo: 400),
            item(id: "suggestion-fresh", lastPlayedDaysAgo: 5),
            item(id: "suggestion-stale", lastPlayedDaysAgo: 400),
            item(id: "unknown-recency")
        ]
        XCTAssertEqual(
            policy.curated(items, now: now).map(\.id),
            ["in-progress-old", "suggestion-fresh", "unknown-recency"]
        )
    }

    func testCurationPreservesOrder() {
        let items = [item(id: "a", lastPlayedDaysAgo: 1), item(id: "b", lastPlayedDaysAgo: 2)]
        XCTAssertEqual(policy.curated(items, now: now).map(\.id), ["a", "b"])
    }

    /// Curation must be safe to apply more than once — the aggregator runs it per
    /// account, and a provider may already have curated its own feed.
    func testCurationIsIdempotent() {
        let items = [
            item(id: "keep", resume: 60, lastPlayedDaysAgo: 500),
            item(id: "drop", lastPlayedDaysAgo: 500)
        ]
        let once = policy.curated(items, now: now)
        XCTAssertEqual(policy.curated(once, now: now).map(\.id), once.map(\.id))
    }

    // MARK: Limits

    /// The row limit was a hardcoded 20 applied twice, which silently discarded
    /// most of a real library's in-progress titles.
    func testDefaultRowLimitHoldsARealLibrary() {
        XCTAssertGreaterThanOrEqual(ContinueWatchingPolicy.default.rowLimit, 47)
    }

    func testRowLimitCannotBeZeroOrNegative() {
        XCTAssertEqual(ContinueWatchingPolicy(rowLimit: 0).rowLimit, 1)
        XCTAssertEqual(ContinueWatchingPolicy(rowLimit: -5).rowLimit, 1)
    }

    func testRefreshWindowCannotBeNegative() {
        XCTAssertEqual(ContinueWatchingPolicy(refreshAfter: -1).refreshAfter, 0)
    }

    /// The window has to leave ordinary navigation alone: stepping into a title
    /// and straight back out must not refetch, or the row reshuffles under the
    /// viewer for no new information.
    /// The window is bounded at both ends, and the upper bound is the one that
    /// caused trouble: at ninety seconds, removing a title in the Plex app and
    /// coming back to the TV took several attempts before Home noticed, which
    /// looked exactly like the staleness bug the window exists to fix.
    ///
    /// The lower bound stops a flick between tabs re-running a fan-out across every
    /// signed-in account. Note what is *not* being protected against: a skeleton
    /// flash or a focus reset, because the refresh this gates is silent.
    func testRefreshWindowIsShortEnoughToNoticeAChangeMadeElsewhere() {
        XCTAssertLessThanOrEqual(
            ContinueWatchingPolicy.default.refreshAfter,
            30,
            "Someone who changes something on another device and walks to the TV should not have to try repeatedly"
        )
        XCTAssertGreaterThanOrEqual(
            ContinueWatchingPolicy.default.refreshAfter,
            5,
            "Flicking between tabs must not re-run a multi-account fan-out each time"
        )
    }

    func testUnboundedKeepsEverything() {
        XCTAssertNil(ContinueWatchingPolicy.unbounded.nextUpCutoff)
        XCTAssertEqual(
            ContinueWatchingPolicy.unbounded.curated(
                [item(id: "a", lastPlayedDaysAgo: 5_000)], now: now
            ).count,
            1
        )
    }
}
