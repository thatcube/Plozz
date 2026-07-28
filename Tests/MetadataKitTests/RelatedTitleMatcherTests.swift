import CoreModels
import XCTest
@testable import MetadataKit

/// Coverage for binding a provider's related title to the viewer's own copy.
///
/// The rule under test is that a **title match is never enough**. Neither Jellyfin
/// nor Plex can look up by external id, so candidates arrive from a free-text
/// search that matches on name alone — which is exactly how "Lucky!" (a 2022
/// documentary) ended up wearing a 2026 drama's schedule. A wrong match here plays
/// the wrong show; a miss costs one row entry.
final class RelatedTitleMatcherTests: XCTestCase {

    private func related(
        _ title: String,
        kind: MediaItemKind = .series,
        ids: [String: String]
    ) -> RelatedTitle {
        RelatedTitle(title: title, kind: kind, providerIDs: ids, source: .trakt)
    }

    private func libraryItem(
        _ id: String,
        title: String,
        kind: MediaItemKind = .series,
        ids: [String: String] = [:]
    ) -> MediaItem {
        MediaItem(id: id, title: title, kind: kind, providerIDs: ids)
    }

    // MARK: The rule

    func testAcceptsOnlyWhenAStrongIDAgrees() {
        let wanted = related("Severance", ids: ["Tmdb": "95396"])
        let hit = libraryItem("jf-1", title: "Severance", ids: ["Tmdb": "95396"])
        XCTAssertEqual(RelatedTitleMatcher.match(wanted, in: [hit])?.id, "jf-1")
    }

    func testRejectsASameTitledShowWithADifferentID() {
        // The Lucky case, in the shape this feature would hit it.
        let wanted = related("Lucky", ids: ["Tmdb": "278624", "Imdb": "tt34866681"])
        let wrong = libraryItem("jf-2", title: "Lucky!", ids: ["Tmdb": "211787", "Imdb": "tt14527704"])
        XCTAssertNil(RelatedTitleMatcher.match(wanted, in: [wrong]))
    }

    func testRejectsAPerfectTitleMatchCarryingNoIDs() {
        // An unmatched library item has no ids to verify against. Showing it because
        // the name agrees is precisely the mistake this type exists to prevent.
        let wanted = related("Dark", ids: ["Tmdb": "70523"])
        let unmatched = libraryItem("jf-3", title: "Dark")
        XCTAssertNil(RelatedTitleMatcher.match(wanted, in: [unmatched]))
    }

    func testRejectsWhenTheRelatedTitleItselfHasNoIDs() {
        let wanted = related("Dark", ids: [:])
        let hit = libraryItem("jf-4", title: "Dark", ids: ["Tmdb": "70523"])
        XCTAssertNil(RelatedTitleMatcher.match(wanted, in: [hit]))
    }

    func testPicksTheVerifiedCandidateOutOfSeveralHits() {
        let wanted = related("The Expanse", ids: ["Imdb": "tt3230854"])
        let hits = [
            libraryItem("jf-a", title: "The Expanse", ids: ["Imdb": "tt9999999"]),
            libraryItem("jf-b", title: "The Expanse (2015)", ids: ["Imdb": "tt3230854"]),
        ]
        XCTAssertEqual(RelatedTitleMatcher.match(wanted, in: hits)?.id, "jf-b")
    }

    // MARK: Kind

    func testAFilmIDNeverMatchesASeriesSharingThatNumber() {
        // TMDb and TheTVDB reuse one integer id space across films and series, so
        // id 550 alone names both a movie and an unrelated show.
        let wanted = related("Fight Club", kind: .movie, ids: ["Tmdb": "550"])
        let show = libraryItem("jf-5", title: "Some Series", kind: .series, ids: ["Tmdb": "550"])
        XCTAssertNil(RelatedTitleMatcher.match(wanted, in: [show]))
    }

    func testAnEpisodeHitStandsInForItsSeries() {
        // A library search for a show routinely surfaces one of its episodes, and
        // that still means the viewer has the show.
        let wanted = related("Silo", ids: ["Tvdb": "403245"])
        let episode = libraryItem(
            "jf-6",
            title: "Freedom Day",
            kind: .episode,
            ids: ["Tvdb": "9999", "SeriesTvdb": "403245"]
        )
        XCTAssertEqual(RelatedTitleMatcher.match(wanted, in: [episode])?.id, "jf-6")
    }

    func testAnEpisodesOwnIDIsNotComparedAgainstAShows() {
        // Reading the episode's own ids would compare an episode id to a series id
        // and reject every candidate — or worse, collide by coincidence.
        let wanted = related("Silo", ids: ["Tvdb": "9999"])
        let episode = libraryItem(
            "jf-7",
            title: "Freedom Day",
            kind: .episode,
            ids: ["Tvdb": "9999", "SeriesTvdb": "403245"]
        )
        XCTAssertNil(RelatedTitleMatcher.match(wanted, in: [episode]))
    }

    // MARK: Recall

    func testIDsAreComparedCaseInsensitively() {
        let wanted = related("Dark", ids: ["Imdb": "TT5753856"])
        let hit = libraryItem("jf-8", title: "Dark", ids: ["Imdb": "tt5753856"])
        XCTAssertNotNil(RelatedTitleMatcher.match(wanted, in: [hit]))
    }

    func testSearchesTheRawTitleFirstThenANormalizedForm() {
        let queries = RelatedTitleMatcher.searchQueries(for: related("The Expanse!", ids: ["Tmdb": "1"]))
        XCTAssertEqual(queries.first, "The Expanse!")
        XCTAssertEqual(queries.count, 2, "a normalized variant widens recall for oddly-stored titles")
    }

    func testABlankTitleYieldsNoQueries() {
        XCTAssertTrue(RelatedTitleMatcher.searchQueries(for: related("   ", ids: ["Tmdb": "1"])).isEmpty)
    }
}
