import XCTest
import CoreModels
@testable import FeatureHome

/// Covers `SeriesHeroNumbering`, the pure derivation that guarantees a TV-show
/// hero shows its "S{n} · E{m}" badge even when the fronted episode (e.g. one
/// seeded from a Search result) arrives without numbers, and the S·E matcher
/// used to re-front the same episode after an in-place cross-server switch.
final class SeriesHeroNumberingTests: XCTestCase {
    private func episode(
        _ id: String,
        season: Int? = nil,
        number: Int? = nil,
        seasonID: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: number.map { "Episode \($0)" } ?? "Episode",
            kind: .episode,
            seasonNumber: season,
            episodeNumber: number,
            seasonID: seasonID
        )
    }

    private func season(_ id: String, number: Int) -> MediaItem {
        MediaItem(id: id, title: "Season \(number)", kind: .season, seasonNumber: number)
    }

    // MARK: numberedHero

    func testKeepsOwnNumbersWhenPresent() {
        let hero = episode("e1", season: 3, number: 7)
        let result = SeriesHeroNumbering.numberedHero(
            hero, seasons: [], loadedEpisodesBySeason: [:],
            selectedSeasonID: nil, selectedSeasonPool: []
        )
        XCTAssertEqual(result.seasonNumber, 3)
        XCTAssertEqual(result.episodeNumber, 7)
        XCTAssertEqual(result.subtitle, "S3 · E7")
    }

    func testNonEpisodeHeroUnchanged() {
        let hero = MediaItem(id: "s", title: "The Show", kind: .series)
        let result = SeriesHeroNumbering.numberedHero(
            hero, seasons: [season("season-1", number: 1)],
            loadedEpisodesBySeason: ["season-1": [episode("e1", season: 1, number: 1)]],
            selectedSeasonID: "season-1", selectedSeasonPool: []
        )
        XCTAssertNil(result.seasonNumber)
        XCTAssertNil(result.episodeNumber)
    }

    func testAdoptsNumbersFromLoadedCounterpartByID() {
        // The Search-path bug: the fronted episode knows only its id; the loaded
        // rail copy carries the authoritative numbers.
        let hero = episode("e1")
        let loaded = ["season-2": [
            episode("e0", season: 2, number: 1),
            episode("e1", season: 2, number: 2),
        ]]
        let result = SeriesHeroNumbering.numberedHero(
            hero, seasons: [], loadedEpisodesBySeason: loaded,
            selectedSeasonID: nil, selectedSeasonPool: []
        )
        XCTAssertEqual(result.seasonNumber, 2)
        XCTAssertEqual(result.episodeNumber, 2)
        XCTAssertEqual(result.subtitle, "S2 · E2")
    }

    func testDerivesSeasonNumberFromOwningSeasonItem() {
        // The episode knows its seasonID but not its season number; the season
        // item supplies it, and position supplies the episode number.
        let hero = episode("e1", seasonID: "season-4")
        let loaded = ["season-4": [
            episode("a", seasonID: "season-4"),
            episode("e1", seasonID: "season-4"),
        ]]
        let result = SeriesHeroNumbering.numberedHero(
            hero, seasons: [season("season-4", number: 4)],
            loadedEpisodesBySeason: loaded,
            selectedSeasonID: nil, selectedSeasonPool: []
        )
        XCTAssertEqual(result.seasonNumber, 4)
        XCTAssertEqual(result.episodeNumber, 2)
    }

    func testFallsBackToPositionInSelectedSeasonPool() {
        let hero = episode("e1")
        let pool = [episode("a"), episode("b"), episode("e1")]
        let result = SeriesHeroNumbering.numberedHero(
            hero, seasons: [season("season-1", number: 1)],
            loadedEpisodesBySeason: [:],
            selectedSeasonID: "season-1", selectedSeasonPool: pool
        )
        XCTAssertEqual(result.seasonNumber, 1)
        XCTAssertEqual(result.episodeNumber, 3)
        XCTAssertEqual(result.subtitle, "S1 · E3")
    }

    func testLeavesNumbersNilWhenGenuinelyUnderivable() {
        // Nothing to derive from — better to leave it blank than invent a number.
        let hero = episode("ghost")
        let result = SeriesHeroNumbering.numberedHero(
            hero, seasons: [], loadedEpisodesBySeason: [:],
            selectedSeasonID: nil, selectedSeasonPool: []
        )
        XCTAssertNil(result.episodeNumber)
        XCTAssertNil(result.subtitle)
    }

    func testLoadedEpisodeWithoutNumberStillGetsPositionalEpisodeNumber() {
        // Counterpart found by id but it too lacks an episodeNumber: fall to its
        // index within that season (still correct), and adopt its seasonNumber.
        let hero = episode("e1")
        let loaded = ["season-1": [
            episode("a", season: 1),
            episode("e1", season: 1),
        ]]
        let result = SeriesHeroNumbering.numberedHero(
            hero, seasons: [], loadedEpisodesBySeason: loaded,
            selectedSeasonID: nil, selectedSeasonPool: []
        )
        XCTAssertEqual(result.seasonNumber, 1)
        XCTAssertEqual(result.episodeNumber, 2)
    }

    // MARK: episode(matching:)

    func testEpisodeMatchingFindsBySeasonAndEpisodeNumber() {
        let pool = [
            episode("x", season: 1, number: 1),
            episode("y", season: 1, number: 2),
            episode("z", season: 2, number: 2),
        ]
        let found = SeriesHeroNumbering.episode(
            matching: SeasonEpisodeRef(season: 2, episode: 2), in: pool
        )
        XCTAssertEqual(found?.id, "z")
    }

    func testEpisodeMatchingReturnsNilWhenAbsent() {
        let pool = [episode("x", season: 1, number: 1)]
        XCTAssertNil(
            SeriesHeroNumbering.episode(
                matching: SeasonEpisodeRef(season: 9, episode: 9), in: pool
            )
        )
    }
}
