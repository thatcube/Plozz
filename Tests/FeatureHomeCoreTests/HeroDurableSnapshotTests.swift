import CoreModels
import XCTest
@testable import FeatureHomeCore

/// The one safety property behind repainting last session's hero: nothing that
/// claims a playback position is ever persisted. A resume goes stale the moment
/// anything is watched anywhere, and a slide restored from disk offering to
/// resume a finished episode is worse than a skeleton.
final class HeroDurableSnapshotTests: XCTestCase {
    private func item(
        _ id: String,
        runtime: TimeInterval? = 7_200,
        resume: TimeInterval? = nil,
        percentage: Double? = nil,
        isPlayed: Bool = false
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: id,
            kind: .movie,
            runtime: runtime,
            resumePosition: resume,
            playedPercentage: percentage,
            isPlayed: isPlayed
        )
    }

    func testAPlainTitleIsDurable() {
        XCTAssertTrue(HeroDurableSnapshot.isDurable(item("a")))
    }

    func testAResumePositionIsNotDurable() {
        XCTAssertFalse(HeroDurableSnapshot.isDurable(item("a", resume: 600)))
    }

    func testAPartWatchedContainerWithOnlyAPercentageIsNotDurable() {
        // Jellyfin synthesises `playedPercentage` on part-watched series and
        // seasons with no `resumePosition` at all, so a container drawn by Random,
        // Watchlist or Recently Added is exactly what slips past a bare
        // resume-position check — and the hero renders it with a Resume CTA.
        XCTAssertFalse(HeroDurableSnapshot.isDurable(item("a", percentage: 0.4)))
    }

    func testAResumePositionWithoutARuntimeIsStillNotDurable() {
        // Without a runtime there is no fraction to compute, so the app's own
        // progress test reports nothing while the position is still real.
        let sparse = item("a", runtime: nil, resume: 600)
        XCTAssertNil(sparse.resumeProgressFraction)
        XCTAssertFalse(HeroDurableSnapshot.isDurable(sparse))
    }

    func testAFinishedTitleIsDurable() {
        // Finished is not resumable: it describes a title, not a position.
        XCTAssertTrue(
            HeroDurableSnapshot.isDurable(
                item("a", resume: nil, percentage: 1, isPlayed: true)
            )
        )
    }

    func testAnotherServersResumeAlsoDisqualifiesIt() {
        // A card's own fields can be clean while a source ref carries the
        // position, and `unifiedWatchState` folds that back onto the card.
        var merged = item("a")
        merged.sources = [
            MediaSourceRef(accountID: "one", itemID: "1", kind: .movie),
            MediaSourceRef(
                accountID: "two",
                itemID: "2",
                kind: .movie,
                resumePosition: 900
            ),
        ]
        XCTAssertNil(merged.resumeProgressFraction)
        XCTAssertFalse(HeroDurableSnapshot.isDurable(merged))
    }

    func testFilterKeepsOrderAndDropsOnlyTheResumables() {
        let items = [
            item("a"),
            item("b", resume: 300),
            item("c"),
            item("d", percentage: 0.2),
        ]

        XCTAssertEqual(HeroDurableSnapshot.filter(items).map(\.id), ["a", "c"])
    }
}
