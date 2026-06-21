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

final class HomeLibraryVisibilityStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.homeVisibility.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testDefaultNamespaceUsesLegacyUnsuffixedKey() {
        let defaults = makeDefaults()
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: nil)
        var v = HomeLibraryVisibility.default
        v.setVisible(false, for: "acct:movies")
        store.save(v)

        // Persisted under the un-suffixed key so upgrading installs inherit it.
        XCTAssertNotNil(defaults.data(forKey: "com.plozz.homeLibraryVisibility"))
        XCTAssertEqual(store.load().excludedKeys, ["acct:movies"])
    }

    func testProfilesGetIsolatedVisibility() {
        let defaults = makeDefaults()
        let alice = HomeLibraryVisibilityStore(defaults: defaults, namespace: "profile-alice")
        let bob = HomeLibraryVisibilityStore(defaults: defaults, namespace: "profile-bob")

        var aliceV = alice.load()
        aliceV.setVisible(false, for: "acct:movies")
        alice.save(aliceV)

        // Bob's scope is untouched by Alice's choice.
        XCTAssertEqual(alice.load().excludedKeys, ["acct:movies"])
        XCTAssertTrue(bob.load().excludedKeys.isEmpty)
        XCTAssertTrue(bob.load().isVisible("acct:movies"))
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
