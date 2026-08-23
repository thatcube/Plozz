import XCTest
import CoreModels
@testable import MetadataKit

/// Guards the rule that an anime provider resolving by fuzzy title search must
/// prove the hit is the title asked for.
///
/// The regression these exist for: House of the Dragon rendered *Dragon Goes
/// House-Hunting*'s poster on the Watchlist, under the correct title and year.
/// Kitsu's `filter[text]` is a relevance search that always answers, AniList was
/// down and so never got to answer first, and nothing checked what came back.
final class AnimeTitleMatchTests: XCTestCase {

    private func query(
        title: String,
        alternate: String? = nil,
        alternates: [String] = []
    ) -> MetadataQuery {
        MetadataQuery(
            contentType: .anime,
            kind: .series,
            title: title,
            alternateTitle: alternate,
            year: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            animeIDs: AnimeIDs(),
            providerIDs: [:],
            titleAlternates: alternates
        )
    }

    // MARK: - Matching

    func testRejectsADifferentWorkThatMerelySharesWords() {
        XCTAssertFalse(
            AnimeTitleMatch.names(
                query(title: "House of the Dragon"),
                among: ["Dragon, Ie wo Kau.", "Dragon Goes House-Hunting", "ドラゴン、家を買う。"]
            ),
            "sharing 'house' and 'dragon' is not being the same show"
        )
    }

    func testAcceptsAnExactMatchOnAnyListedTitle() {
        XCTAssertTrue(
            AnimeTitleMatch.names(
                query(title: "Frieren: Beyond Journey's End"),
                among: ["Sousou no Frieren", "Frieren: Beyond Journey's End", "葬送のフリーレン"]
            ),
            "a romaji canonical title must not stop the English one from matching"
        )
    }

    func testFoldsPunctuationAndCase() {
        XCTAssertTrue(
            AnimeTitleMatch.names(
                query(title: "Kaguya-sama: Love Is War"),
                among: ["Kaguya-sama wa Kokurasetai", "KAGUYA SAMA: LOVE IS WAR"]
            )
        )
    }

    func testAllowsATrailingSeasonSuffix() {
        XCTAssertTrue(
            AnimeTitleMatch.names(
                query(title: "Attack on Titan Season 3"),
                among: ["Attack on Titan"]
            ),
            "a library's season folder is still the catalogue's show"
        )
    }

    func testMatchesAnAlternateTitleTheCallerOffered() {
        XCTAssertTrue(
            AnimeTitleMatch.names(
                query(title: "Shingeki no Kyojin", alternates: ["Attack on Titan"]),
                among: ["Attack on Titan"]
            )
        )
    }

    func testNoCandidateTitlesIsNotAMatch() {
        XCTAssertFalse(
            AnimeTitleMatch.names(query(title: "Bleach"), among: [nil, "", "   "]),
            "a provider that lists no name has not identified anything"
        )
    }

    func testEmptyQueryTitleIsNotAMatch() {
        XCTAssertFalse(AnimeTitleMatch.names(query(title: "  "), among: ["Bleach"]))
    }

    // MARK: - Kitsu candidate selection

    private func kitsuAttributes(_ json: String) throws -> KitsuArtworkProvider.Attributes {
        try JSONDecoder().decode(
            KitsuArtworkProvider.Attributes.self,
            from: Data(json.utf8)
        )
    }

    func testKitsuDecodesNullTitleValues() throws {
        let attributes = try kitsuAttributes("""
        {
          "canonicalTitle": "Dragon, Ie wo Kau.",
          "titles": {"en": null, "en_jp": "Dragon, Ie wo Kau.", "ja_jp": "ドラゴン、家を買う。"},
          "abbreviatedTitles": [],
          "posterImage": {"original": "https://kitsu/poster.jpg", "large": null},
          "coverImage": null
        }
        """)
        XCTAssertEqual(attributes.canonicalTitle, "Dragon, Ie wo Kau.")
        XCTAssertEqual(attributes.posterImage?.original, "https://kitsu/poster.jpg")
        XCTAssertTrue(
            attributes.allTitles.contains("ドラゴン、家を買う。"),
            "a nullable locale value must not take the whole record down with it"
        )
    }

    func testKitsuReturnsNothingWhenNoCandidateNamesTheTitle() throws {
        // The exact payload Kitsu answers `filter[text]=House of the Dragon` with.
        let candidates = [
            try kitsuAttributes("""
            {"canonicalTitle": "Dragon, Ie wo Kau.",
             "titles": {"en": "Dragon Goes House-Hunting", "en_jp": "Dragon, Ie wo Kau."},
             "posterImage": {"original": "https://kitsu/wrong.jpg", "large": null},
             "coverImage": null}
            """),
            try kitsuAttributes("""
            {"canonicalTitle": "Fortune Quest L",
             "titles": {"en": "Fortune Quest"},
             "posterImage": null, "coverImage": null}
            """),
        ]
        XCTAssertNil(
            KitsuArtworkProvider.bestMatch(
                for: query(title: "House of the Dragon"),
                among: candidates
            ),
            "no art is the right answer when the catalogue does not have the title"
        )
    }

    func testKitsuPicksTheMatchBehindAMoreRelevantMiss() throws {
        let candidates = [
            try kitsuAttributes("""
            {"canonicalTitle": "Bleach: Sennen Kessen-hen",
             "titles": {"en": "Bleach: Thousand-Year Blood War"},
             "posterImage": {"original": "https://kitsu/tybw.jpg", "large": null},
             "coverImage": null}
            """),
            try kitsuAttributes("""
            {"canonicalTitle": "Bleach",
             "titles": {"en": "Bleach"},
             "posterImage": {"original": "https://kitsu/bleach.jpg", "large": null},
             "coverImage": null}
            """),
        ]
        let match = KitsuArtworkProvider.bestMatch(
            for: query(title: "Bleach"),
            among: candidates
        )
        XCTAssertEqual(
            match?.posterImage?.original,
            "https://kitsu/bleach.jpg",
            "relevance order does not decide identity — the titles do"
        )
    }

    func testKitsuReturnsNothingForAnEmptyResultSet() {
        XCTAssertNil(
            KitsuArtworkProvider.bestMatch(for: query(title: "Bleach"), among: [])
        )
    }

    // MARK: - AniList candidate titles

    func testAniListCollectsEveryNameItListed() {
        let media = AniListArtworkProvider.Media(
            id: 21,
            idMal: 21,
            averageScore: nil,
            bannerImage: nil,
            coverImage: nil,
            title: AniListArtworkProvider.Media.Title(
                romaji: "Sousou no Frieren",
                english: "Frieren: Beyond Journey's End",
                native: "葬送のフリーレン"
            ),
            synonyms: ["Frieren at the Funeral"]
        )
        XCTAssertTrue(
            AnimeTitleMatch.names(
                query(title: "Frieren at the Funeral"),
                among: media.allTitles
            ),
            "synonyms are where a library's spelling often lives"
        )
        XCTAssertFalse(
            AnimeTitleMatch.names(query(title: "House of the Dragon"), among: media.allTitles)
        )
    }
}
