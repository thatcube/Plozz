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

    private func absolute(_ number: Int, daysFromNow: Int) -> UpcomingEpisode {
        UpcomingEpisode(
            seriesIdentity: .external(source: "anilist", value: "1"),
            absoluteEpisodeNumber: number,
            airDate: now.addingTimeInterval(Double(daysFromNow) * 86_400),
            datePrecision: .dateAndTime,
            source: .anilist,
            refreshedAt: now
        )
    }

    func testAcceptsAnAbsoluteEntryThatContinuesAnAbsoluteOrderedLibrary() {
        // A library using absolute ordering (Plex's absolute mode, long-running
        // shonen) shows E1086, so AniList's absolute 1087 is the next episode.
        let items = SeriesUpcoming.placeholders(
            for: 1,
            seriesID: "s1",
            seriesTitle: "One Piece",
            ownedEpisodes: [owned(season: 1, episode: 1086)],
            schedule: [absolute(1087, daysFromNow: 5)]
        )
        XCTAssertEqual(items.map(\.episodeNumber), [1087])
    }

    func testRejectsAnAbsoluteEntryAgainstAPerSeasonLibrary() {
        // The same library organised per season shows E4; an "episode 1087" card
        // beside it would be unrelated to what's on screen.
        let items = SeriesUpcoming.placeholders(
            for: 23,
            seriesID: "s1",
            seriesTitle: "One Piece",
            ownedEpisodes: [owned(season: 23, episode: 4)],
            schedule: [absolute(1087, daysFromNow: 5)]
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testAcceptsAnAbsoluteEntryForASingleSeasonAnime() {
        // Seasonal cour anime: absolute and per-season numbering coincide, so
        // AniList's absolute 5 correctly continues a library showing E1–E4.
        let items = SeriesUpcoming.placeholders(
            for: 1,
            seriesID: "s1",
            seriesTitle: "Cour Anime",
            ownedEpisodes: (1...4).map { owned(season: 1, episode: $0) },
            schedule: [absolute(5, daysFromNow: 6)]
        )
        XCTAssertEqual(items.map(\.episodeNumber), [5])
    }

    func testRejectsAnAbsoluteEntryWhenNothingIsOwned() {
        // With no episodes on screen there is no sequence to continue, so there is
        // nothing to match against and the entry stays out rather than being guessed.
        let items = SeriesUpcoming.placeholders(
            for: 1,
            seriesID: "s1",
            seriesTitle: "Anime",
            ownedEpisodes: [],
            schedule: [absolute(5, daysFromNow: 3)]
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testPerSeasonEntriesStillWinWhenBothNumberingsAreOffered() {
        // AniList and TVmaze can both answer; the per-season entry matches the
        // library's own shape and must not be crowded out by the absolute one.
        let items = SeriesUpcoming.placeholders(
            for: 1,
            seriesID: "s1",
            seriesTitle: "Anime",
            ownedEpisodes: (1...4).map { owned(season: 1, episode: $0) },
            schedule: [
                upcoming(season: 1, episode: 5, daysFromNow: 6, title: "Per season"),
                absolute(5, daysFromNow: 6),
            ]
        )
        XCTAssertEqual(items.first?.title, "Per season")
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
        XCTAssertEqual(english(line), "New episode tomorrow")
    }

    func testUsesTheCadenceForAnEpisodeFurtherOut() {
        let line = SeriesUpcoming.heroLine(
            nextEpisode: upcoming(season: 3, episode: 5, daysFromNow: 20),
            cadence: AirCadence(weekdays: [6]),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(english(line), "New episodes on Friday")
    }

    func testCallsAFirstEpisodeANewSeason() {
        let line = SeriesUpcoming.heroLine(
            nextEpisode: upcoming(season: 4, episode: 1, daysFromNow: 30),
            cadence: AirCadence(weekdays: [6]),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(english(line)?.hasPrefix("New season"), true, "A premiere's date is the news, not the cadence")
    }

    func testNamesTheDateWhenAProviderReportsNoCadence() {
        let line = SeriesUpcoming.heroLine(
            nextEpisode: upcoming(season: 3, episode: 5, daysFromNow: 30),
            cadence: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(english(line)?.hasPrefix("New episode "), true)
        XCTAssertFalse(english(line)?.contains("Fridays") == true)
    }

    func testNeverClaimsACadenceForAMultiDayRelease() {
        // Two airing days can't be phrased as "New episodes Xs".
        let line = SeriesUpcoming.heroLine(
            nextEpisode: upcoming(season: 3, episode: 5, daysFromNow: 30),
            cadence: AirCadence(weekdays: [2, 5]),
            now: now,
            calendar: calendar
        )
        XCTAssertFalse(english(line)?.contains("New episodes") == true)
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
    // MARK: Batch drops

    func testNamesAFullSeasonDropRatherThanAPremiere() {
        // Every upcoming episode of the season shares one date: the whole season
        // lands at once, which is different news from a weekly premiere.
        let batch = (1...8).map { upcoming(season: 7, episode: $0, daysFromNow: 40) }
        let line = SeriesUpcoming.heroLine(
            nextEpisode: batch[0],
            cadence: nil,
            schedule: batch,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(english(line)?.hasPrefix("Full season releases"), true)
        XCTAssertFalse(
            english(line)?.contains("available") == true,
            "Plozz reads the viewer's own server; it can't promise the episodes will be in their library"
        )
    }

    func testTreatsAMultiEpisodePremiereFollowedByWeeklyAsANewSeason() {
        // Percy Jackson opens with two episodes on one day, then goes weekly. The
        // ongoing cadence is what matters after opening night.
        var run = [
            upcoming(season: 3, episode: 1, daysFromNow: 40),
            upcoming(season: 3, episode: 2, daysFromNow: 40),
        ]
        run += (3...8).map { upcoming(season: 3, episode: $0, daysFromNow: 40 + ($0 - 2) * 7) }
        let line = SeriesUpcoming.heroLine(
            nextEpisode: run[0],
            cadence: nil,
            schedule: run,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(english(line)?.hasPrefix("New season"), true)
    }

    func testASingleKnownEpisodeIsNotABatch() {
        // One dated episode says nothing about how the rest of the season lands.
        let only = [upcoming(season: 4, episode: 1, daysFromNow: 30)]
        let line = SeriesUpcoming.heroLine(
            nextEpisode: only[0],
            cadence: nil,
            schedule: only,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(english(line)?.hasPrefix("New season"), true)
    }

    func testABatchOfAnotherSeasonDoesNotChangeThisPremiere() {
        let mixed = [
            upcoming(season: 3, episode: 1, daysFromNow: 40),
            upcoming(season: 4, episode: 1, daysFromNow: 200),
            upcoming(season: 4, episode: 2, daysFromNow: 200),
        ]
        let line = SeriesUpcoming.heroLine(
            nextEpisode: mixed[0],
            cadence: nil,
            schedule: mixed,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(english(line)?.hasPrefix("New season"), true)
    }

    // MARK: Weekly runs

    func testClaimsEveryFridayOnlyWhenTheDatesProveIt() {
        // Three episodes, each a week apart: the pattern is visible in the data.
        let run = (5...8).map { upcoming(season: 3, episode: $0, daysFromNow: ($0 - 5) * 7 + 10) }
        let line = SeriesUpcoming.heroLine(
            nextEpisode: run[0],
            cadence: nil,
            schedule: run,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(english(line)?.hasPrefix("New episode every "), true)
    }

    func testDoesNotClaimEveryWeekFromASingleRemainingEpisode() {
        // A lone finale says nothing about a continuing schedule.
        let finale = [upcoming(season: 3, episode: 10, daysFromNow: 12)]
        let line = SeriesUpcoming.heroLine(
            nextEpisode: finale[0],
            cadence: nil,
            schedule: finale,
            now: now,
            calendar: calendar
        )
        XCTAssertFalse(english(line)?.contains("every") == true)
    }

    func testDoesNotClaimEveryWeekAcrossAMidSeasonBreak() {
        // A gap breaks the run, so the weekly claim would be wrong past the break.
        let broken = [
            upcoming(season: 3, episode: 5, daysFromNow: 10),
            upcoming(season: 3, episode: 6, daysFromNow: 17),
            upcoming(season: 3, episode: 7, daysFromNow: 45),
        ]
        let line = SeriesUpcoming.heroLine(
            nextEpisode: broken[0],
            cadence: nil,
            schedule: broken,
            now: now,
            calendar: calendar
        )
        XCTAssertFalse(english(line)?.contains("every") == true)
    }

    func testFallsBackToTheStatedDayWhenTheRunIsUnproven() {
        // Only the provider's stated slot is known, so it is phrased without "every".
        let sparse = [upcoming(season: 3, episode: 5, daysFromNow: 20)]
        let line = SeriesUpcoming.heroLine(
            nextEpisode: sparse[0],
            cadence: AirCadence(weekdays: [6]),
            schedule: sparse,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(english(line), "New episodes on Friday")
    }

    private func english(
        _ resource: LocalizedStringResource?
    ) -> String? {
        resource.map { String(localized: $0) }
    }
}
