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

    // MARK: - Two-level enabled / show-on-home semantics

    func testDefaultsMergeOnNothingDisabled() {
        let v = HomeLibraryVisibility.default
        XCTAssertTrue(v.mergeLibrariesOnHome)
        XCTAssertTrue(v.disabledKeys.isEmpty)
        XCTAssertTrue(v.isEnabled("acct:anything"))
        XCTAssertTrue(v.isShownOnHome("acct:anything"))
        XCTAssertTrue(v.isVisibleOnHome("acct:anything"))
    }

    func testEnabledAndShownOnHomeAreIndependent() {
        var v = HomeLibraryVisibility.default
        // Hidden from Home only: still enabled (available in Search/Music), just
        // not on Home.
        v.setShownOnHome(false, for: "acct:movies")
        XCTAssertTrue(v.isEnabled("acct:movies"))
        XCTAssertFalse(v.isShownOnHome("acct:movies"))
        XCTAssertFalse(v.isVisibleOnHome("acct:movies"))
    }

    func testDisablingHidesEverywhereButPreservesHomeChoice() {
        var v = HomeLibraryVisibility.default
        v.setShownOnHome(true, for: "acct:movies") // explicitly on Home
        v.setEnabled(false, for: "acct:movies")    // disable app-wide

        XCTAssertFalse(v.isEnabled("acct:movies"))
        // The Home-only bit is preserved (still "shown") so re-enabling restores it…
        XCTAssertTrue(v.isShownOnHome("acct:movies"))
        // …but while disabled it is not visible on Home.
        XCTAssertFalse(v.isVisibleOnHome("acct:movies"))
        XCTAssertFalse(v.isVisible("acct:movies"), "isVisible aliases isVisibleOnHome")

        v.setEnabled(true, for: "acct:movies")
        XCTAssertTrue(v.isVisibleOnHome("acct:movies"), "re-enabling restores the prior Home choice")
    }

    func testCodableRoundTripPreservesAllFields() throws {
        var v = HomeLibraryVisibility.default
        v.mergeLibrariesOnHome = false
        v.setEnabled(false, for: "a:1")
        v.setShownOnHome(false, for: "b:2")

        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)

        XCTAssertFalse(decoded.mergeLibrariesOnHome)
        XCTAssertEqual(decoded.disabledKeys, ["a:1"])
        XCTAssertEqual(decoded.excludedKeys, ["b:2"])
    }

    func testLegacyBlobDecodesWithMergeOnAndNothingDisabled() throws {
        // A pre-feature blob only ever carried `excludedKeys`. It must decode with
        // merge ON (classic behaviour) and nothing disabled, so upgrading installs
        // see zero Home change until they opt in.
        let legacy = #"{"excludedKeys":["acct:movies"]}"#
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: Data(legacy.utf8))

        XCTAssertTrue(decoded.mergeLibrariesOnHome)
        XCTAssertTrue(decoded.disabledKeys.isEmpty)
        XCTAssertEqual(decoded.excludedKeys, ["acct:movies"])
        XCTAssertFalse(decoded.isVisibleOnHome("acct:movies"))
        XCTAssertTrue(decoded.isEnabled("acct:movies"))
        // New row-selection fields also default sensibly: every global row on, no
        // per-library rows opted in.
        XCTAssertTrue(decoded.isGlobalRowEnabled(.continueWatching))
        XCTAssertTrue(decoded.isGlobalRowEnabled(.recentlyAdded))
        XCTAssertFalse(decoded.isLibraryRowEnabled("acct:movies", kind: .recentlyAdded))
    }

    // MARK: - Global & per-library Home rows

    func testGlobalRowsDefaultOnAndToggleOff() {
        var v = HomeLibraryVisibility.default
        for row in HomeGlobalRow.allCases {
            XCTAssertTrue(v.isGlobalRowEnabled(row), "\(row) should default on")
        }
        v.setGlobalRowEnabled(false, for: .watchlist)
        XCTAssertFalse(v.isGlobalRowEnabled(.watchlist))
        XCTAssertTrue(v.isGlobalRowEnabled(.continueWatching), "other rows unaffected")
        XCTAssertEqual(v.disabledGlobalHomeRows, ["watchlist"])
    }

    func testPerLibraryRowsDefaultOffAndOptIn() {
        var v = HomeLibraryVisibility.default
        XCTAssertFalse(v.isLibraryRowEnabled("acct:L1", kind: .recentlyAdded))
        v.setLibraryRowEnabled(true, libraryKey: "acct:L1", kind: .recentlyAdded)
        XCTAssertTrue(v.isLibraryRowEnabled("acct:L1", kind: .recentlyAdded))
        // Independent per kind and per library.
        XCTAssertFalse(v.isLibraryRowEnabled("acct:L1", kind: .hubs))
        XCTAssertFalse(v.isLibraryRowEnabled("acct:L2", kind: .recentlyAdded))
        v.setLibraryRowEnabled(false, libraryKey: "acct:L1", kind: .recentlyAdded)
        XCTAssertTrue(v.enabledLibraryHomeRows.isEmpty)
    }

    func testRowSelectionSurvivesCodableRoundTrip() throws {
        var v = HomeLibraryVisibility.default
        v.setGlobalRowEnabled(false, for: .recentlyAdded)
        v.setLibraryRowEnabled(true, libraryKey: "acct:L1", kind: .hubs)

        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)

        XCTAssertFalse(decoded.isGlobalRowEnabled(.recentlyAdded))
        XCTAssertTrue(decoded.isLibraryRowEnabled("acct:L1", kind: .hubs))
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

final class HomeLibraryVisibilityModelTests: XCTestCase {
    @MainActor
    private func makeModel() -> HomeLibraryVisibilityModel {
        let suite = "test.homeVisibilityModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
    }

    @MainActor
    func testSetMergePersistsAndReads() {
        let model = makeModel()
        XCTAssertTrue(model.mergeLibrariesOnHome)
        model.setMergeLibrariesOnHome(false)
        XCTAssertFalse(model.mergeLibrariesOnHome)
        XCTAssertFalse(model.visibility.mergeLibrariesOnHome)
    }

    @MainActor
    func testSetEnabledIsIndependentOfShownOnHome() {
        let model = makeModel()
        model.setShownOnHome(true, for: "acct:movies")
        model.setEnabled(false, for: "acct:movies")

        XCTAssertFalse(model.isEnabled("acct:movies"))
        XCTAssertTrue(model.isShownOnHome("acct:movies"))
        XCTAssertFalse(model.isVisibleOnHome("acct:movies"))
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
