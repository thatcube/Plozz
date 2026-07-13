import XCTest
@testable import MetadataKit

/// Coverage for `TVDBClient.titlesMatch`, the fuzzy episode-title comparison that
/// backs same-name series disambiguation (e.g. animated "Archer" vs the 1975
/// detective drama). Matching is tolerant of casing, punctuation, and leftover
/// scene/quality remnants, while never matching on a bare numeric overlap.
final class TVDBTitleMatchTests: XCTestCase {

    func testExactTitlesMatch() {
        XCTAssertTrue(TVDBClient.titlesMatch("Mole Hunt", "Mole Hunt"))
    }

    func testCaseAndPunctuationInsensitive() {
        XCTAssertTrue(TVDBClient.titlesMatch("Dial M for Mother", "dial m for mother!"))
        XCTAssertTrue(TVDBClient.titlesMatch("Skorpio", "SKORPIO"))
    }

    func testLeftoverSceneRemnantStillMatchesViaSubset() {
        // Local parser occasionally leaves a trailing quality token; the TVDB name
        // is a subset of the on-disk tokens, so they still match.
        XCTAssertTrue(TVDBClient.titlesMatch("Training Day", "Training Day proper"))
    }

    func testDifferentTitlesDoNotMatch() {
        XCTAssertFalse(TVDBClient.titlesMatch("Mole Hunt", "The Underground Man"))
    }

    func testDisjointTitlesDoNotMatch() {
        XCTAssertFalse(TVDBClient.titlesMatch("Honeypot", "Skytanic"))
    }

    func testNumericOnlyOverlapDoesNotMatch() {
        // Bare numbers are dropped, so "Episode 1" vs "Chapter 1" share no real token.
        XCTAssertFalse(TVDBClient.titlesMatch("Episode 1", "Chapter 1"))
    }

    func testEmptyTitleNeverMatches() {
        XCTAssertFalse(TVDBClient.titlesMatch("", "Mole Hunt"))
        XCTAssertFalse(TVDBClient.titlesMatch("Mole Hunt", "   "))
    }

    // MARK: - normalizedTitleKey (exact-title preference over relevance)

    func testNormalizedTitleKeyFoldsPunctuationAndCase() {
        // A spinoff's on-disk title and TheTVDB's canonical name must key equal so
        // "The Witcher: Blood Origin" is preferred over the parent "The Witcher".
        XCTAssertEqual(
            TVDBClient.normalizedTitleKey("The Witcher Blood Origin"),
            TVDBClient.normalizedTitleKey("The Witcher: Blood Origin")
        )
        // The parent keys DIFFERENTLY, so it is not treated as an exact match.
        XCTAssertNotEqual(
            TVDBClient.normalizedTitleKey("The Witcher Blood Origin"),
            TVDBClient.normalizedTitleKey("The Witcher")
        )
        XCTAssertEqual(TVDBClient.normalizedTitleKey("Ávatar—2024"), "avatar 2024")
    }

    // MARK: - Non-canonical variant rejection

    func testAddsUnrequestedVariantRejectsAbridged() {
        // A plain "Sword Art Online" folder must not match the "Abridged" parody.
        XCTAssertTrue(TVDBClient.addsUnrequestedVariant(name: "Sword Art Online: Abridged", query: "Sword Art Online"))
        XCTAssertTrue(TVDBClient.addsUnrequestedVariant(name: "Naruto Recap", query: "Naruto"))
        // The real show is never rejected.
        XCTAssertFalse(TVDBClient.addsUnrequestedVariant(name: "Sword Art Online", query: "Sword Art Online"))
        // If the query itself asks for the variant, it's allowed.
        XCTAssertFalse(TVDBClient.addsUnrequestedVariant(name: "Sword Art Online Abridged", query: "Sword Art Online Abridged"))
        XCTAssertFalse(TVDBClient.addsUnrequestedVariant(name: nil, query: "Whatever"))
    }

    // MARK: - Non-Latin detection (drives the English-translation overlay)

    func testIsNonLatinText() {
        XCTAssertTrue(TVDBClient.isNonLatinText("「そのノートに名前を書かれた人間は死ぬ」"))   // Japanese
        XCTAssertTrue(TVDBClient.isNonLatinText("Сериал"))                                    // Cyrillic
        XCTAssertFalse(TVDBClient.isNonLatinText("A high-school student finds a notebook."))   // English
        XCTAssertFalse(TVDBClient.isNonLatinText(nil))
        XCTAssertFalse(TVDBClient.isNonLatinText(""))
    }

    // MARK: - Foreign Latin-script title detection (drives English overlay)

    func testTitleResembles() {
        // Same / prefix-related titles resemble the query and are trusted as-is.
        XCTAssertTrue(TVDBClient.titleResembles("The Eternaut", "The Eternaut"))
        XCTAssertTrue(TVDBClient.titleResembles("Avatar The Last Airbender", "Avatar"))
        XCTAssertTrue(TVDBClient.titleResembles("Halo", "halo"))
        // A foreign primary name does NOT resemble the English folder → triggers the
        // English-translation fetch.
        XCTAssertFalse(TVDBClient.titleResembles("El eternauta", "The Eternaut"))
        XCTAssertFalse(TVDBClient.titleResembles(nil, "Whatever"))
    }
}
