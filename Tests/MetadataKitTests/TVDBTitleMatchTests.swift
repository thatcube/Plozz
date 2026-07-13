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
}
