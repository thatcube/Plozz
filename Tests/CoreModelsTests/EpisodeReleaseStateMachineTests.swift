import XCTest
@testable import CoreModels

final class EpisodeReleaseStateMachineTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000_000)

    private func episode(season: Int?, number: Int?, id: String = UUID().uuidString) -> MediaItem {
        var item = MediaItem(id: id, title: "Ep", kind: .episode)
        item.seasonNumber = season
        item.episodeNumber = number
        return item
    }

    private func westernUpcoming(season: Int, episode: Int, airDate: Date, precision: AirDatePrecision = .dateAndTime) -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: .external(source: "tvmaze", value: "1"),
            seasonNumber: season, episodeNumber: episode,
            airDate: airDate, datePrecision: precision, source: .tvmaze, refreshedAt: epoch)
    }

    private func animeUpcoming(absolute: Int, airDate: Date) -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: .external(source: "anilist", value: "21"),
            absoluteEpisodeNumber: absolute,
            airDate: airDate, datePrecision: .dateAndTime, source: .anilist, refreshedAt: epoch)
    }

    // MARK: Presence

    func testFutureEpisodeAbsentIsUpcoming() {
        let up = westernUpcoming(season: 1, episode: 2, airDate: epoch.addingTimeInterval(3600))
        let presence = EpisodePresenceIndex(ownedEpisodes: [episode(season: 1, number: 1)])
        let state = EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: epoch)
        XCTAssertEqual(state, .upcoming(up))
    }

    func testFutureEpisodePresentIsPresentNotSyntheticCard() {
        let up = westernUpcoming(season: 1, episode: 2, airDate: epoch.addingTimeInterval(3600))
        let owned = episode(season: 1, number: 2, id: "owned")
        let presence = EpisodePresenceIndex(ownedEpisodes: [episode(season: 1, number: 1), owned])
        let state = EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: epoch)
        XCTAssertEqual(state, .present(item: owned))
    }

    func testPresentAcrossSeveralOwnedCopiesPicksOne() {
        let up = westernUpcoming(season: 2, episode: 3, airDate: epoch)
        // Two sources each expose the same episode; the index keeps the first.
        let a = episode(season: 2, number: 3, id: "a")
        let b = episode(season: 2, number: 3, id: "b")
        let presence = EpisodePresenceIndex(ownedEpisodes: [a, b])
        let state = EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: epoch)
        XCTAssertEqual(state, .present(item: a))
    }

    // MARK: Grace period (exact timestamp)

    func testExactAiredWithinGraceThenMissing() {
        let air = epoch
        let up = westernUpcoming(season: 1, episode: 5, airDate: air)
        let presence = EpisodePresenceIndex(ownedEpisodes: [])
        // 1h after air, default 6h grace -> just aired.
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: air.addingTimeInterval(3600)),
            .airedGracePeriod(up))
        // 7h after air -> missing.
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: air.addingTimeInterval(7 * 3600)),
            .airedMissing(up))
    }

    // MARK: Grace period (date-only) waits until the following local day

    func testDateOnlyGraceLastsUntilNextLocalDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let grace = EpisodeGraceConfig(exactGrace: 6 * 3600, calendar: cal)
        // Air day start (local midnight) for 2030-05-01.
        var comps = DateComponents()
        comps.year = 2030; comps.month = 5; comps.day = 1
        comps.timeZone = cal.timeZone
        let airDay = cal.date(from: comps)!
        let up = UpcomingEpisode(
            seriesIdentity: .external(source: "tvdb", value: "9"),
            seasonNumber: 1, episodeNumber: 1,
            airDate: airDay, datePrecision: .dateOnly, source: .tvdb, refreshedAt: epoch)
        let presence = EpisodePresenceIndex(ownedEpisodes: [])
        // Same local day, evening -> still "aired today".
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: airDay.addingTimeInterval(20 * 3600), grace: grace),
            .airedGracePeriod(up))
        // Next local day -> missing.
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: airDay.addingTimeInterval(25 * 3600), grace: grace),
            .airedMissing(up))
    }

    // MARK: Later library arrival transitions to present (recompute)

    func testLaterArrivalRecomputesToPresent() {
        let up = westernUpcoming(season: 1, episode: 2, airDate: epoch)
        let empty = EpisodePresenceIndex(ownedEpisodes: [])
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(upcoming: up, presence: empty, now: epoch.addingTimeInterval(10 * 3600)),
            .airedMissing(up))
        // The episode later shows up on a source; recompute yields present.
        let owned = episode(season: 1, number: 2, id: "late")
        let arrived = EpisodePresenceIndex(ownedEpisodes: [owned])
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(upcoming: up, presence: arrived, now: epoch.addingTimeInterval(10 * 3600)),
            .present(item: owned))
    }

    // MARK: Anime absolute numbering (no unsafe season conversion)

    func testAnimeAbsolutePresentInFlatLayout() {
        let up = animeUpcoming(absolute: 1075, airDate: epoch.addingTimeInterval(3600))
        // Flat anime layout: season 1 (or nil), episode number == absolute.
        let owned = episode(season: 1, number: 1075, id: "abs")
        let presence = EpisodePresenceIndex(ownedEpisodes: [owned, episode(season: nil, number: 1074)])
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: epoch),
            .present(item: owned))
    }

    func testAnimeAbsoluteDoesNotConvertAcrossRealSeasons() {
        let up = animeUpcoming(absolute: 26, airDate: epoch.addingTimeInterval(3600))
        // Owned uses real multi-season numbering (S2E2). We must NOT guess that
        // S2E2 == absolute 26 -> the episode reads as not-yet-present (upcoming).
        let presence = EpisodePresenceIndex(ownedEpisodes: [episode(season: 2, number: 2)])
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: epoch),
            .upcoming(up))
    }

    func testWesternScheduleIgnoresAbsoluteOnlyOwned() {
        // A per-season schedule must not match an absolute-only owned set by number.
        let up = westernUpcoming(season: 3, episode: 4, airDate: epoch.addingTimeInterval(3600))
        let presence = EpisodePresenceIndex(ownedEpisodes: [episode(season: 1, number: 4)])
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(upcoming: up, presence: presence, now: epoch),
            .upcoming(up))
    }

    // MARK: No schedule / ended series

    func testNoScheduleYieldsNilState() {
        let presence = EpisodePresenceIndex(ownedEpisodes: [episode(season: 1, number: 1)])
        XCTAssertNil(EpisodeReleaseStateMachine.state(upcoming: nil, presence: presence, now: epoch))
    }

    // MARK: Seerr reflection precedence (Phase 3 wiring uses this)

    func testSeerrRequestReflectsInsteadOfMissing() {
        let up = westernUpcoming(season: 1, episode: 9, airDate: epoch)
        let presence = EpisodePresenceIndex(ownedEpisodes: [])
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(
                upcoming: up, presence: presence, seerStatus: .pending,
                now: epoch.addingTimeInterval(10 * 3600)),
            .requested(up))
        // Available is not a "requested" reflection (it becomes present via library).
        XCTAssertEqual(
            EpisodeReleaseStateMachine.state(
                upcoming: up, presence: presence, seerStatus: .available,
                now: epoch.addingTimeInterval(10 * 3600)),
            .airedMissing(up))
    }
}
