import XCTest
@testable import MetadataKit

/// Coverage for how same-name TheTVDB candidates are ordered before episode-title
/// scoring. Only the first few candidates have their episode lists fetched, so an
/// ordering that drops the real show never gets the chance to recognise it.
final class TVDBCandidateOrderingTests: XCTestCase {

    private func key(_ query: String) -> String {
        TVDBClient.normalizedTitleKey(query)
    }

    // MARK: The year TheTVDB appends to a re-used name

    func testTheYearSuffixedNamesakeCountsAsNamingTheQuery() {
        // TheTVDB disambiguates a re-used name on the *newer* entry, so "Lucky
        // (2026)" and "Lucky!" both answer to a "Lucky" folder.
        XCTAssertTrue(TVDBClient.namesQueriedTitle("Lucky (2026)", query: key("Lucky")))
        XCTAssertTrue(TVDBClient.namesQueriedTitle("Lucky!", query: key("Lucky")))
    }

    func testADifferentShowIsStillNotAMatch() {
        XCTAssertFalse(TVDBClient.namesQueriedTitle("Lucky Hank", query: key("Lucky")))
        XCTAssertFalse(TVDBClient.namesQueriedTitle("Lucky Luke (2026)", query: key("Lucky")))
    }

    func testOnlyATrailingFourDigitYearIsStripped() {
        XCTAssertEqual(TVDBClient.stripTrailingYear("Lucky (2026)"), "Lucky")
        XCTAssertEqual(TVDBClient.stripTrailingYear("Lucky (UK)"), "Lucky (UK)")
        XCTAssertEqual(TVDBClient.stripTrailingYear("Lucky (20260)"), "Lucky (20260)")
        XCTAssertEqual(TVDBClient.stripTrailingYear("Lucky"), "Lucky")
        XCTAssertEqual(TVDBClient.stripTrailingYear("(2026)"), "")
    }

    func testAnEmptyQueryNeverMatches() {
        XCTAssertFalse(TVDBClient.namesQueriedTitle("Lucky", query: ""))
        XCTAssertFalse(TVDBClient.namesQueriedTitle(nil, query: key("Lucky")))
    }
}
