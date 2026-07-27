import XCTest
import CoreModels
@testable import FeatureHomeCore

final class SeriesResumeTests: XCTestCase {
    private func episode(
        _ id: String,
        number: Int,
        played: Bool = false,
        percentage: Double? = nil,
        resume: TimeInterval? = nil,
        playedAt: Date? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: "Episode \(number)",
            kind: .episode,
            episodeNumber: number,
            resumePosition: resume,
            playedPercentage: percentage,
            isPlayed: played,
            lastPlayedAt: playedAt
        )
    }

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 86_400)
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

    // MARK: recency

    /// The case that ordering alone gets wrong: everything up to E10 watched, E11
    /// onward not. Continue from where they actually were.
    func testResumesAfterTheMostRecentlyCompletedEpisode() {
        let items = [
            episode("e9", number: 9, played: true, playedAt: day(1)),
            episode("e10", number: 10, played: true, playedAt: day(5)),
            episode("e11", number: 11),
            episode("e12", number: 12)
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e11")
    }

    /// Watched out of order — E5 watched most recently, E2 skipped. Resume after
    /// E5 rather than doubling back to the earliest gap.
    func testOutOfOrderViewingResumesFromTheMostRecentNotTheEarliestGap() {
        let items = [
            episode("e1", number: 1, played: true, playedAt: day(1)),
            episode("e2", number: 2),
            episode("e3", number: 3),
            episode("e4", number: 4, played: true, playedAt: day(2)),
            episode("e5", number: 5, played: true, playedAt: day(9)),
            episode("e6", number: 6)
        ]
        XCTAssertEqual(
            SeriesResume.nextUp(in: items)?.id, "e6",
            "continue from the most recent watch, not the earliest unwatched episode"
        )
    }

    /// Two part-watched episodes: the one touched most recently wins, not the one
    /// that happens to sort first.
    func testMostRecentInProgressWinsOverEarlierInProgress() {
        let items = [
            episode("e2", number: 2, percentage: 0.3, playedAt: day(1)),
            episode("e7", number: 7, percentage: 0.6, playedAt: day(4))
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e7")
    }

    /// An in-progress episode still outranks "the one after the most recently
    /// completed" — a half-watched episode is the strongest resume signal there is.
    func testInProgressBeatsTheEpisodeAfterTheLastCompleted() {
        let items = [
            episode("e1", number: 1, percentage: 0.4, playedAt: day(1)),
            episode("e2", number: 2, played: true, playedAt: day(6)),
            episode("e3", number: 3)
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e1")
    }

    /// Without timestamps the comparison has nothing to sort on and must degrade
    /// to the previous list-order behaviour rather than picking arbitrarily.
    func testFallsBackToListOrderWithoutTimestamps() {
        let items = [
            episode("e1", number: 1, played: true),
            episode("e2", number: 2, played: true),
            episode("e3", number: 3)
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e3")
    }

    /// Most recent completed is the finale, so there is nothing after it — fall
    /// through to the remaining gap rather than returning nil.
    func testFallsBackToTheEarlierGapWhenNothingFollowsTheLastWatched() {
        let items = [
            episode("e1", number: 1),
            episode("e2", number: 2, played: true, playedAt: day(3))
        ]
        XCTAssertEqual(SeriesResume.nextUp(in: items)?.id, "e1")
    }

    // MARK: hasStarted / isFinished / restingHero

    private func show() -> MediaItem {
        MediaItem(id: "show", title: "Test Show", kind: .series)
    }

    /// The pool is read from the seasons because episodes are only ever loaded one
    /// season at a time: someone who finished S1 and opened on S2 sees nothing but
    /// unwatched episodes, and would look like they had never started.
    func testHasStartedReadsSeasonsNotTheLoadedEpisodePool() {
        let seasons = [
            season("s1", number: 1, played: true, percentage: 1, hasBeenPlayed: true),
            season("s2", number: 2)
        ]
        let loadedSeasonTwoEpisodes = [episode("e1", number: 1), episode("e2", number: 2)]
        XCTAssertTrue(
            SeriesResume.hasStarted(seasons: seasons, episodes: loadedSeasonTwoEpisodes)
        )
    }

    /// `allSatisfy` is vacuously true on an empty collection, so an unloaded show
    /// would otherwise report itself finished.
    func testEmptyShowIsNotFinished() {
        XCTAssertFalse(SeriesResume.isFinished(seasons: [], episodes: []))
        XCTAssertFalse(SeriesResume.hasStarted(seasons: [], episodes: []))
    }

    func testFinishedShowRestsOnTheSeries() {
        let seasons = [season("s1", number: 1, played: true, percentage: 1, hasBeenPlayed: true)]
        let episodes = [episode("e1", number: 1, played: true, playedAt: day(1))]
        XCTAssertEqual(
            SeriesResume.restingHero(series: show(), seasons: seasons, episodes: episodes).id,
            "show",
            "a finished series starts over — the episode pointer is stale"
        )
    }

    func testUnstartedShowRestsOnTheSeries() {
        let seasons = [season("s1", number: 1)]
        let episodes = [episode("e1", number: 1)]
        XCTAssertEqual(
            SeriesResume.restingHero(series: show(), seasons: seasons, episodes: episodes).id,
            "show"
        )
    }

    func testPartWatchedShowRestsOnTheResumeEpisode() {
        let seasons = [season("s1", number: 1, hasBeenPlayed: true)]
        let episodes = [
            episode("e1", number: 1, played: true, playedAt: day(2)),
            episode("e2", number: 2)
        ]
        XCTAssertEqual(
            SeriesResume.restingHero(series: show(), seasons: seasons, episodes: episodes).id,
            "e2"
        )
    }

    /// A flat loose-episode show has no season containers, so the episode list is
    /// the whole show and answers for itself.
    func testFlatShowWithNoSeasonsUsesItsEpisodes() {
        let episodes = [
            episode("e1", number: 1, played: true, playedAt: day(1)),
            episode("e2", number: 2)
        ]
        XCTAssertTrue(SeriesResume.hasStarted(seasons: [], episodes: episodes))
        XCTAssertEqual(
            SeriesResume.restingHero(series: show(), seasons: [], episodes: episodes).id,
            "e2"
        )
    }

    // MARK: restart season

    /// Season 0 is specials and sorts ahead of Season 1 — "start from the
    /// beginning" must not open on a Christmas special.
    func testRestartSkipsSpecials() {
        let seasons = [
            season("s0", number: 0),
            season("s1", number: 1),
            season("s2", number: 2)
        ]
        XCTAssertEqual(SeriesResume.restartSeason(in: seasons)?.id, "s1")
    }

    func testRestartUsesSpecialsWhenTheyAreAllThereIs() {
        let seasons = [season("s0", number: 0)]
        XCTAssertEqual(SeriesResume.restartSeason(in: seasons)?.id, "s0")
    }

    func testRestartOnEmptySeasonsIsNil() {
        XCTAssertNil(SeriesResume.restartSeason(in: []))
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
