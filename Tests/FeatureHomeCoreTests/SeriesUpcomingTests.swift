import XCTest
import CoreModels
@testable import FeatureHomeCore

/// The rules that decide what an unaired episode looks like on the series page.
final class SeriesUpcomingTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func upcoming(
        season: Int?,
        episode: Int?,
        daysFromNow: Int,
        title: String? = nil
    ) -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: .external(source: "tvdb", value: "1"),
            seasonNumber: season,
            episodeNumber: episode,
            title: title,
            airDate: now.addingTimeInterval(Double(daysFromNow) * 86_400),
            datePrecision: .dateOnly,
            source: .tvdb,
            refreshedAt: now
        )
    }

    private func owned(season: Int, episode: Int) -> MediaItem {
        MediaItem(
            id: "owned-s\(season)e\(episode)",
            title: "Owned \(episode)",
            kind: .episode,
            seasonNumber: season,
            episodeNumber: episode
        )
    }

    // MARK: Placeholders

    func testListsOnlyTheRequestedSeasonsUnairedEpisodes() {
        let items = SeriesUpcoming.placeholders(
            for: 3,
            seriesID: "s1",
            seriesTitle: "Silo",
            ownedEpisodes: [owned(season: 3, episode: 4)],
            schedule: [
                upcoming(season: 3, episode: 5, daysFromNow: 4, title: "Memory"),
                upcoming(season: 3, episode: 6, daysFromNow: 11, title: "The Drive"),
                upcoming(season: 4, episode: 1, daysFromNow: 200, title: "Next season"),
            ]
        )
        XCTAssertEqual(items.map(\.episodeNumber), [5, 6], "A different season's schedule must not leak in")
        XCTAssertTrue(items.allSatisfy { $0.isUpcomingUnaired })
        XCTAssertEqual(items.first?.title, "Memory")
    }

    func testDropsEpisodesTheServerAlreadyHas() {
        // A server can carry an episode before the schedule catches up; showing both
        // would duplicate the card.
        let items = SeriesUpcoming.placeholders(
            for: 3,
            seriesID: "s1",
            seriesTitle: "Silo",
            ownedEpisodes: [owned(season: 3, episode: 5)],
            schedule: [upcoming(season: 3, episode: 5, daysFromNow: 2, title: "Memory")]
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testDropsAbsoluteNumberedEntriesThatKnowNoSeason() {
        // AniList reports an absolute episode number and no season; attributing it to
        // a season would be a guess.
        let items = SeriesUpcoming.placeholders(
            for: 3,
            seriesID: "s1",
            seriesTitle: "One Piece",
            ownedEpisodes: [],
            schedule: [upcoming(season: nil, episode: nil, daysFromNow: 3)]
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testPlaceholdersAreNeverPlayable() {
        let items = SeriesUpcoming.placeholders(
            for: 1,
            seriesID: "s1",
            seriesTitle: "Show",
            ownedEpisodes: [],
            schedule: [upcoming(season: 1, episode: 2, daysFromNow: 5)]
        )
        let item = try? XCTUnwrap(items.first)
        XCTAssertNotNil(item?.scheduledAirDate)
        XCTAssertTrue(item?.isUpcomingUnaired == true)
    }

    func testUsesTheEpisodeNumberWhenAProviderGivesNoTitle() {
        let items = SeriesUpcoming.placeholders(
            for: 1,
            seriesID: "s1",
            seriesTitle: "Show",
            ownedEpisodes: [],
            schedule: [upcoming(season: 1, episode: 7, daysFromNow: 5)]
        )
        XCTAssertEqual(items.first?.title, "Episode 7")
    }

    // MARK: Hero line

    func testNamesTheDateForAnImminentEpisodeRatherThanTheCadence() {
        // "Fridays" is vaguer than "tomorrow" when it airs tomorrow.
        let line = SeriesUpcoming.heroLine(
            nextEpisode: upcoming(season: 3, episode: 5, daysFromNow: 1),
            cadence: AirCadence(weekdays: [6]),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(line, "New episode tomorrow")
    }

    func testUsesTheCadenceForAnEpisodeFurtherOut() {
        let line = SeriesUpcoming.heroLine(
            nextEpisode: upcoming(season: 3, episode: 5, daysFromNow: 20),
            cadence: AirCadence(weekdays: [6]),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(line, "New episodes Fridays")
    }

    func testCallsAFirstEpisodeANewSeason() {
        let line = SeriesUpcoming.heroLine(
            nextEpisode: upcoming(season: 4, episode: 1, daysFromNow: 30),
            cadence: AirCadence(weekdays: [6]),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(line?.hasPrefix("New season"), true, "A premiere's date is the news, not the cadence")
    }

    func testNamesTheDateWhenAProviderReportsNoCadence() {
        let line = SeriesUpcoming.heroLine(
            nextEpisode: upcoming(season: 3, episode: 5, daysFromNow: 30),
            cadence: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(line?.hasPrefix("New episode "), true)
        XCTAssertFalse(line?.contains("Fridays") == true)
    }

    func testNeverClaimsACadenceForAMultiDayRelease() {
        // Two airing days can't be phrased as "New episodes Xs".
        let line = SeriesUpcoming.heroLine(
            nextEpisode: upcoming(season: 3, episode: 5, daysFromNow: 30),
            cadence: AirCadence(weekdays: [2, 5]),
            now: now,
            calendar: calendar
        )
        XCTAssertFalse(line?.contains("New episodes") == true)
    }

    func testSaysNothingWithoutASchedule() {
        XCTAssertNil(SeriesUpcoming.heroLine(nextEpisode: nil, cadence: nil, now: now, calendar: calendar))
    }

    // MARK: Card caption

    func testCardCaptionPrefersARelativeDay() {
        let item = SeriesUpcoming.placeholders(
            for: 1,
            seriesID: "s",
            seriesTitle: "Show",
            ownedEpisodes: [],
            schedule: [upcoming(season: 1, episode: 2, daysFromNow: 1)]
        ).first
        XCTAssertEqual(
            item.flatMap { SeriesUpcoming.cardCaption(for: $0, now: now, calendar: calendar) },
            "Tomorrow"
        )
    }

    func testCardCaptionFallsBackToADateFurtherOut() {
        let item = SeriesUpcoming.placeholders(
            for: 1,
            seriesID: "s",
            seriesTitle: "Show",
            ownedEpisodes: [],
            schedule: [upcoming(season: 1, episode: 2, daysFromNow: 40)]
        ).first
        let caption = item.flatMap { SeriesUpcoming.cardCaption(for: $0, now: now, calendar: calendar) }
        XCTAssertNotNil(caption)
        XCTAssertFalse(caption?.contains("Tomorrow") == true)
    }

    func testOrdinaryEpisodesHaveNoAirDateCaption() {
        XCTAssertNil(SeriesUpcoming.cardCaption(for: owned(season: 1, episode: 1), now: now, calendar: calendar))
    }
}
