import XCTest
@testable import CoreModels

final class EpisodeReleaseDisplayTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_900_000_000) // 2030-03-17
    private let enUS = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func western(title: String? = "Chapter 5", precision: AirDatePrecision = .dateAndTime) -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: .external(source: "tvmaze", value: "1"),
            seasonNumber: 1, episodeNumber: 2, title: title,
            airDate: epoch, datePrecision: precision, source: .tvmaze, refreshedAt: epoch)
    }

    func testUpcomingBadgeNumberAndDate() {
        let d = EpisodeReleaseDisplay.make(for: .upcoming(western()), spoilersEnabled: false, locale: enUS, timeZone: utc)
        XCTAssertEqual(d.badge, "Airing soon")
        XCTAssertEqual(d.numberLabel, "S1 E2")
        XCTAssertEqual(d.title, "Chapter 5")
        XCTAssertTrue(d.isExpectedNotGuaranteed)
        XCTAssertTrue(d.summaryLine.hasPrefix("Airing soon · S1 E2 · "))
    }

    func testSpoilersHideTitleButKeepNumberAndDate() {
        let d = EpisodeReleaseDisplay.make(for: .upcoming(western()), spoilersEnabled: true, locale: enUS, timeZone: utc)
        XCTAssertNil(d.title, "Spoiler mode hides the upcoming title")
        XCTAssertEqual(d.numberLabel, "S1 E2")
        XCTAssertNotNil(d.dateLabel)
    }

    func testAbsoluteAnimeNumberLabel() {
        let anime = UpcomingEpisode(
            seriesIdentity: .external(source: "anilist", value: "21"),
            absoluteEpisodeNumber: 1075, airDate: epoch, datePrecision: .dateAndTime,
            source: .anilist, refreshedAt: epoch)
        let d = EpisodeReleaseDisplay.make(for: .upcoming(anime), spoilersEnabled: false, locale: enUS, timeZone: utc)
        XCTAssertEqual(d.numberLabel, "Ep 1075")
    }

    func testExactTimestampIncludesTimeDateOnlyDoesNot() {
        let exact = EpisodeReleaseDisplay.make(for: .upcoming(western(precision: .dateAndTime)), spoilersEnabled: false, locale: enUS, timeZone: utc)
        XCTAssertTrue(exact.dateLabel?.contains(":") ?? false, "An exact schedule localizes a time")
        let dateOnly = EpisodeReleaseDisplay.make(for: .upcoming(western(precision: .dateOnly)), spoilersEnabled: false, locale: enUS, timeZone: utc)
        XCTAssertFalse(dateOnly.dateLabel?.contains(":") ?? true, "A date-only schedule invents no time")
    }

    func testBadgesPerState() {
        let up = western()
        XCTAssertEqual(EpisodeReleaseDisplay.make(for: .airedGracePeriod(up), spoilersEnabled: false, locale: enUS, timeZone: utc).badge, "Aired today")
        XCTAssertEqual(EpisodeReleaseDisplay.make(for: .airedMissing(up), spoilersEnabled: false, locale: enUS, timeZone: utc).badge, "Not in your library")
        XCTAssertEqual(EpisodeReleaseDisplay.make(for: .requested(up), spoilersEnabled: false, locale: enUS, timeZone: utc).badge, "Requested")
        var item = MediaItem(id: "x", title: "Ep", kind: .episode)
        item.seasonNumber = 1; item.episodeNumber = 2
        let present = EpisodeReleaseDisplay.make(for: .present(item: item), spoilersEnabled: false, locale: enUS, timeZone: utc)
        XCTAssertNil(present.badge)
        XCTAssertFalse(present.isExpectedNotGuaranteed)
    }

    func testRequestedIsDefiniteNotEstimated() {
        XCTAssertFalse(EpisodeReleaseDisplay.make(for: .requested(western()), spoilersEnabled: false, locale: enUS, timeZone: utc).isExpectedNotGuaranteed)
    }
}

final class HomeScheduleRowBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    private func series(_ id: String) -> MediaItem { MediaItem(id: id, title: id, kind: .series) }

    private func upcoming(_ series: String, season: Int, episode: Int, airOffset: TimeInterval) -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: .external(source: "tvmaze", value: series),
            seasonNumber: season, episodeNumber: episode,
            airDate: now.addingTimeInterval(airOffset), datePrecision: .dateAndTime,
            source: .tvmaze, refreshedAt: now)
    }

    private let noEpisodes = EpisodePresenceIndex(ownedEpisodes: [])

    func testAiringSoonSortedSoonestFirstMissingSortedMostRecentFirst() {
        let contexts = [
            // Airing soon (future), out of order.
            SeriesScheduleContext(series: series("A"), upcoming: upcoming("A", season: 1, episode: 2, airOffset: 3 * 86400), presence: noEpisodes),
            SeriesScheduleContext(series: series("B"), upcoming: upcoming("B", season: 1, episode: 2, airOffset: 1 * 86400), presence: noEpisodes),
            // Aired + absent past grace, out of order.
            SeriesScheduleContext(series: series("C"), upcoming: upcoming("C", season: 1, episode: 5, airOffset: -10 * 86400), presence: noEpisodes),
            SeriesScheduleContext(series: series("D"), upcoming: upcoming("D", season: 1, episode: 5, airOffset: -2 * 86400), presence: noEpisodes),
        ]
        let rows = HomeScheduleRowBuilder.rows(from: contexts, now: now)
        XCTAssertEqual(rows.airingSoon.map(\.series.id), ["B", "A"], "Soonest first")
        XCTAssertEqual(rows.recentlyAiredMissing.map(\.series.id), ["D", "C"], "Most recently aired first")
    }

    func testPresentGraceAndRequestedExcludedFromRows() {
        let owned = { () -> MediaItem in var e = MediaItem(id: "e", title: "e", kind: .episode); e.seasonNumber = 1; e.episodeNumber = 2; return e }()
        let contexts = [
            // Present -> excluded.
            SeriesScheduleContext(series: series("P"), upcoming: upcoming("P", season: 1, episode: 2, airOffset: -5 * 86400),
                                  presence: EpisodePresenceIndex(ownedEpisodes: [owned])),
            // Grace period (aired 1h ago) -> excluded.
            SeriesScheduleContext(series: series("G"), upcoming: upcoming("G", season: 1, episode: 2, airOffset: -3600), presence: noEpisodes),
            // Requested (aired, absent, but Seerr in flight) -> excluded from missing.
            SeriesScheduleContext(series: series("R"), upcoming: upcoming("R", season: 1, episode: 2, airOffset: -5 * 86400),
                                  presence: noEpisodes, seerStatus: .processing),
        ]
        let rows = HomeScheduleRowBuilder.rows(from: contexts, now: now)
        XCTAssertTrue(rows.airingSoon.isEmpty)
        XCTAssertTrue(rows.recentlyAiredMissing.isEmpty)
    }
}
