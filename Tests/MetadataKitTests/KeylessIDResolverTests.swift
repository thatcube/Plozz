import XCTest
@testable import MetadataKit

/// Coverage for the keyless external-id resolver used by share enrichment. The
/// live AniList/TVmaze lookups aren't exercised here (no network in unit tests);
/// these assert the routing contract: movies return empty (no cheap keyless movie
/// id source), and the resolver never crashes/hangs on empty input.
final class KeylessIDResolverTests: XCTestCase {
    func testMoviesReturnEmpty() async {
        let ids = await KeylessIDResolver().externalIDs(title: "Some Film", year: 2020, isAnime: false, isTV: false)
        XCTAssertTrue(ids.isEmpty, "no keyless movie-id source in this phase — must return empty, not error")
    }

    func testEmptyTitleReturnsEmpty() async {
        let ids = await KeylessIDResolver().externalIDs(title: "   ", year: nil, isAnime: true, isTV: false)
        XCTAssertTrue(ids.isEmpty)
    }
}
