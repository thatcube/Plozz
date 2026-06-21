import XCTest
@testable import CoreModels

final class HomeLibraryVisibilityTests: XCTestCase {
    func testDefaultShowsEverything() {
        let visibility = HomeLibraryVisibility.default
        XCTAssertTrue(visibility.isVisible("acct:anything"))
        XCTAssertTrue(visibility.excludedKeys.isEmpty)
    }

    func testHidingAndShowingAKey() {
        var visibility = HomeLibraryVisibility.default
        visibility.setVisible(false, for: "acct:movies")

        XCTAssertFalse(visibility.isVisible("acct:movies"))
        XCTAssertTrue(visibility.isVisible("acct:shows"), "Other libraries stay visible (opt-out)")

        visibility.setVisible(true, for: "acct:movies")
        XCTAssertTrue(visibility.isVisible("acct:movies"))
        XCTAssertTrue(visibility.excludedKeys.isEmpty)
    }

    func testNewlyDiscoveredLibraryIsVisibleByDefault() {
        var visibility = HomeLibraryVisibility.default
        visibility.setVisible(false, for: "acct:movies")
        // A library the user has never toggled is visible automatically.
        XCTAssertTrue(visibility.isVisible("acct:newly-added"))
    }

    func testCodableRoundTripPreservesExclusions() throws {
        var visibility = HomeLibraryVisibility.default
        visibility.setVisible(false, for: "a:1")
        visibility.setVisible(false, for: "b:2")

        let data = try JSONEncoder().encode(visibility)
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)

        XCTAssertEqual(decoded.excludedKeys, ["a:1", "b:2"])
        XCTAssertFalse(decoded.isVisible("a:1"))
        XCTAssertTrue(decoded.isVisible("a:3"))
    }
}

final class AggregatedLibraryTests: XCTestCase {
    private func make(accountID: String, libraryID: String) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: accountID,
            accountName: "Alice",
            serverName: "Home",
            providerKind: .jellyfin,
            library: MediaLibrary(id: libraryID, title: "Movies", kind: .movie)
        )
    }

    func testKeyCombinesAccountAndLibrary() {
        XCTAssertEqual(make(accountID: "acct-1", libraryID: "L9").key, "acct-1:L9")
    }

    func testKeyIsStableAndIdentifierMatches() {
        let aggregated = make(accountID: "acct-1", libraryID: "L9")
        XCTAssertEqual(aggregated.id, aggregated.key)
    }

    func testSameLibraryIDOnDifferentAccountsHasDistinctKeys() {
        let a = make(accountID: "acct-1", libraryID: "L1")
        let b = make(accountID: "acct-2", libraryID: "L1")
        XCTAssertNotEqual(a.key, b.key)
    }
}

final class MediaItemSourceTaggingTests: XCTestCase {
    func testTaggingStampsSourceAccount() {
        let item = MediaItem(id: "m1", title: "Dune", kind: .movie)
        XCTAssertNil(item.sourceAccountID)
        XCTAssertEqual(item.taggingSource("acct-1").sourceAccountID, "acct-1")
    }

    func testLibraryTaggingStampsSourceAccount() {
        let library = MediaLibrary(id: "L1", title: "Movies", kind: .movie)
        XCTAssertNil(library.sourceAccountID)
        XCTAssertEqual(library.taggingSource("acct-1").sourceAccountID, "acct-1")
    }

    func testSourceAccountIDDecodesAsNilFromLegacyData() throws {
        // Legacy JSON without the field decodes with sourceAccountID == nil.
        let legacy = #"{"id":"m1","title":"Dune","kind":"movie","isPlayed":false,"ratings":[],"providerIDs":{}}"#
        let data = Data(legacy.utf8)
        let item = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertNil(item.sourceAccountID)
        XCTAssertEqual(item.id, "m1")
    }
}
