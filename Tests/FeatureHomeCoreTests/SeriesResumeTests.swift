import XCTest
import CoreModels
@testable import FeatureHomeCore

final class SeriesResumeTests: XCTestCase {
    private func episode(
        _ id: String,
        number: Int,
        played: Bool = false,
        percentage: Double? = nil,
        resume: TimeInterval? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: "Episode \(number)",
            kind: .episode,
            episodeNumber: number,
            resumePosition: resume,
            playedPercentage: percentage,
            isPlayed: played
        )
    }

    // MARK: nextUp selection

    func testNextUpPicksFirstInProgressByPercentage() {
        let items = [
            episode("e1", number: 1, played: true, percentage: 1),
            episode("e2", number: 2, percentage: 0.4),
            episode("e3", number: 3),
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e2")
    }

    func testNextUpPicksInProgressByResumePositionEvenIfNoPercentage() {
        let items = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, resume: 600),
            episode("e3", number: 3),
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e2")
    }

    func testNextUpFallsBackToFirstUnwatchedWhenNothingInProgress() {
        // e131 watched, e132 next — the canonical "auto-advance" case.
        let items = [
            episode("e131", number: 131, played: true, percentage: 1),
            episode("e132", number: 132),
            episode("e133", number: 133),
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e132")
    }

    func testNextUpPrefersInProgressOverEarlierUnwatched() {
        // An earlier unwatched item exists, but an in-progress one wins.
        let items = [
            episode("e1", number: 1),
            episode("e2", number: 2, percentage: 0.5),
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e2")
    }

    func testNextUpReturnsLastWhenEverythingWatched() {
        let items = [
            episode("e1", number: 1, played: true, percentage: 1),
            episode("e2", number: 2, played: true, percentage: 1),
            episode("e3", number: 3, played: true, percentage: 1),
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e3")
    }

    func testNextUpReturnsNilForEmpty() {
        XCTAssertNil(SeriesResume.nextUp(in: []))
    }

    func testPlayedItemIsNotInProgressEvenWithResumePosition() {
        // A fully-played item with stale progress data is not "resumable".
        let item = episode("e1", number: 1, played: true, percentage: 0.5, resume: 300)
        XCTAssertFalse(SeriesResume.isInProgress(item))
    }

    func testFullyProgressedItemIsNotInProgress() {
        XCTAssertFalse(SeriesResume.isInProgress(episode("e1", number: 1, percentage: 1)))
    }

    func testZeroProgressItemIsNotInProgress() {
        XCTAssertFalse(SeriesResume.isInProgress(episode("e1", number: 1, percentage: 0, resume: 0)))
    }

    // MARK: container progress

    private func season(
        _ id: String,
        number: Int,
        played: Bool = false,
        percentage: Double? = nil,
        hasBeenPlayed: Bool = false
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: "Season \(number)",
            kind: .season,
            seasonNumber: number,
            playedPercentage: percentage,
            isPlayed: played,
            hasBeenPlayed: hasBeenPlayed
        )
    }

    /// A container has no resume position of its own, and its percentage counts
    /// only *completed* episodes — so a season whose first episode is half-watched
    /// reports no percentage at all. Its progress is "started, not finished".
    func testStartedSeasonIsInProgressWithoutPercentageOrResume() {
        XCTAssertTrue(
            SeriesResume.isInProgress(season("s3", number: 3, hasBeenPlayed: true))
        )
    }

    func testUntouchedSeasonIsNotInProgress() {
        XCTAssertFalse(SeriesResume.isInProgress(season("s1", number: 1)))
    }

    func testCompletedSeasonIsNotInProgress() {
        XCTAssertFalse(
            SeriesResume.isInProgress(
                season("s2", number: 2, played: true, percentage: 1, hasBeenPlayed: true)
            )
        )
    }

    /// The reported bug: Season 2 marked fully watched, Season 3 started, Season 1
    /// never touched. Resolving "which season is the viewer on" must answer S3 —
    /// before this, S3 looked untouched, so it fell through to "first unwatched"
    /// and opened on Season 1.
    func testSeasonsResolveToTheStartedOneNotTheFirstUnwatched() {
        let seasons = [
            season("s1", number: 1),
            season("s2", number: 2, played: true, percentage: 1, hasBeenPlayed: true),
            season("s3", number: 3, hasBeenPlayed: true)
        ]
        XCTAssertEqual(
            SeriesResume.nextUp(in: seasons)?.id, "s3",
            "a started season outranks an earlier never-started one"
        )
    }

    /// An episode must NOT inherit the container rule: a leaf that has been played
    /// before but carries no resume position is a finished rewatch candidate, not
    /// something to resume mid-way.
    func testPlayedBeforeEpisodeIsNotInProgressWithoutResume() {
        var replayed = episode("e1", number: 1)
        replayed.hasBeenPlayed = true
        XCTAssertFalse(SeriesResume.isInProgress(replayed))
    }

    // MARK: timecode formatting

    func testTimecodeUnderAnHour() {
        XCTAssertEqual(PlaybackTimecode.string(from: 0), "0:00")
        XCTAssertEqual(PlaybackTimecode.string(from: 9), "0:09")
        XCTAssertEqual(PlaybackTimecode.string(from: 65), "1:05")
        XCTAssertEqual(PlaybackTimecode.string(from: 600), "10:00")
        XCTAssertEqual(PlaybackTimecode.string(from: 3599), "59:59")
    }

    func testTimecodeOverAnHour() {
        XCTAssertEqual(PlaybackTimecode.string(from: 3600), "1:00:00")
        XCTAssertEqual(PlaybackTimecode.string(from: 3661), "1:01:01")
        XCTAssertEqual(PlaybackTimecode.string(from: 7325), "2:02:05")
    }

    func testTimecodeTruncatesFractionalSeconds() {
        XCTAssertEqual(PlaybackTimecode.string(from: 65.9), "1:05")
    }

    func testTimecodeClampsNegativeAndNonFinite() {
        XCTAssertEqual(PlaybackTimecode.string(from: -42), "0:00")
        XCTAssertEqual(PlaybackTimecode.string(from: .infinity), "0:00")
        XCTAssertEqual(PlaybackTimecode.string(from: .nan), "0:00")
    }
}
