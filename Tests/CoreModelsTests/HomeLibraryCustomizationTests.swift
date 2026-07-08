import XCTest
@testable import CoreModels

final class HomeLibraryVisibilityTests: XCTestCase {
    func testDefaultShowsEverything() {
        let visibility = HomeLibraryVisibility.default
        XCTAssertTrue(visibility.isVisible("acct:anything"))
        XCTAssertTrue(visibility.disabledKeys.isEmpty)
    }

    func testDisablingAndEnablingAKey() {
        var visibility = HomeLibraryVisibility.default
        visibility.setEnabled(false, for: "acct:movies")

        XCTAssertFalse(visibility.isVisible("acct:movies"))
        XCTAssertTrue(visibility.isVisible("acct:shows"), "Other libraries stay on (opt-out)")

        visibility.setEnabled(true, for: "acct:movies")
        XCTAssertTrue(visibility.isVisible("acct:movies"))
        XCTAssertTrue(visibility.disabledKeys.isEmpty)
    }

    func testNewlyDiscoveredLibraryIsEnabledByDefault() {
        var visibility = HomeLibraryVisibility.default
        visibility.setEnabled(false, for: "acct:movies")
        // A library the user has never toggled is on automatically.
        XCTAssertTrue(visibility.isVisible("acct:newly-added"))
    }

    func testCodableRoundTripPreservesDisabledKeys() throws {
        var visibility = HomeLibraryVisibility.default
        visibility.setEnabled(false, for: "a:1")
        visibility.setEnabled(false, for: "b:2")

        let data = try JSONEncoder().encode(visibility)
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)

        XCTAssertEqual(decoded.disabledKeys, ["a:1", "b:2"])
        XCTAssertFalse(decoded.isVisible("a:1"))
        XCTAssertTrue(decoded.isVisible("a:3"))
    }

    // MARK: - Single on/off axis (the Home-only opt-out was retired)

    func testDefaultsMergeOnNothingDisabled() {
        let v = HomeLibraryVisibility.default
        XCTAssertTrue(v.mergeLibrariesOnHome)
        XCTAssertTrue(v.disabledKeys.isEmpty)
        XCTAssertTrue(v.isEnabled("acct:anything"))
        XCTAssertTrue(v.isVisibleOnHome("acct:anything"))
    }

    func testVisibleOnHomeIsJustEnabled() {
        var v = HomeLibraryVisibility.default
        // There is no separate Home-only opt-out anymore: on Home == enabled.
        XCTAssertTrue(v.isVisibleOnHome("acct:movies"))
        v.setEnabled(false, for: "acct:movies")
        XCTAssertFalse(v.isEnabled("acct:movies"))
        XCTAssertFalse(v.isVisibleOnHome("acct:movies"))
        XCTAssertFalse(v.isVisible("acct:movies"), "isVisible aliases isVisibleOnHome")
    }

    func testDisablingHidesEverywhereAndReEnablingRestores() {
        var v = HomeLibraryVisibility.default
        v.setEnabled(false, for: "acct:movies")
        XCTAssertFalse(v.isEnabled("acct:movies"))
        XCTAssertFalse(v.isVisibleOnHome("acct:movies"))

        v.setEnabled(true, for: "acct:movies")
        XCTAssertTrue(v.isVisibleOnHome("acct:movies"))
    }

    func testCodableRoundTripPreservesAllFields() throws {
        var v = HomeLibraryVisibility.default
        v.mergeLibrariesOnHome = false
        v.setEnabled(false, for: "a:1")

        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)

        XCTAssertFalse(decoded.mergeLibrariesOnHome)
        XCTAssertEqual(decoded.disabledKeys, ["a:1"])
    }

    func testLegacyExcludedKeysBlobDecodesAsShown() throws {
        // A pre-retirement blob carried the old Home-only `excludedKeys` opt-out.
        // It must still decode (merge ON, nothing disabled), and the retired axis
        // is dropped — an excluded-but-enabled library now simply shows on Home.
        let legacy = #"{"excludedKeys":["acct:movies"]}"#
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: Data(legacy.utf8))

        XCTAssertTrue(decoded.mergeLibrariesOnHome)
        XCTAssertTrue(decoded.disabledKeys.isEmpty)
        XCTAssertTrue(decoded.isEnabled("acct:movies"))
        XCTAssertTrue(decoded.isVisibleOnHome("acct:movies"), "retired opt-out folds to shown")
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
        v.setEnabled(false, for: "acct:movies")
        store.save(v)

        // Persisted under the un-suffixed key so upgrading installs inherit it.
        XCTAssertNotNil(defaults.data(forKey: "com.plozz.homeLibraryVisibility"))
        XCTAssertEqual(store.load().disabledKeys, ["acct:movies"])
    }

    func testProfilesGetIsolatedVisibility() {
        let defaults = makeDefaults()
        let alice = HomeLibraryVisibilityStore(defaults: defaults, namespace: "profile-alice")
        let bob = HomeLibraryVisibilityStore(defaults: defaults, namespace: "profile-bob")

        var aliceV = alice.load()
        aliceV.setEnabled(false, for: "acct:movies")
        alice.save(aliceV)

        // Bob's scope is untouched by Alice's choice.
        XCTAssertEqual(alice.load().disabledKeys, ["acct:movies"])
        XCTAssertTrue(bob.load().disabledKeys.isEmpty)
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
    func testSetEnabledControlsVisibility() {
        let model = makeModel()
        XCTAssertTrue(model.isVisibleOnHome("acct:movies"))
        model.setEnabled(false, for: "acct:movies")

        XCTAssertFalse(model.isEnabled("acct:movies"))
        XCTAssertFalse(model.isVisibleOnHome("acct:movies"))

        model.setEnabled(true, for: "acct:movies")
        XCTAssertTrue(model.isVisibleOnHome("acct:movies"))
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

    // MARK: - Seeding per-library rows when first unmerging

    func testSeedLibraryRowsFillsEverythingWhenFirstUnmerging() {
        var visibility = HomeLibraryVisibility.default
        XCTAssertFalse(visibility.hasSeededLibraryRows)
        let seeded = visibility.seedLibraryRowsIfNeeded([
            ("acct:movies", .recentlyAdded),
            ("acct:movies", .hubs),
            ("acct:shows", .recentlyAdded)
        ])

        XCTAssertTrue(seeded)
        XCTAssertTrue(visibility.hasSeededLibraryRows)
        XCTAssertTrue(visibility.isLibraryRowEnabled("acct:movies", kind: .recentlyAdded))
        XCTAssertTrue(visibility.isLibraryRowEnabled("acct:movies", kind: .hubs))
        XCTAssertTrue(visibility.isLibraryRowEnabled("acct:shows", kind: .recentlyAdded))
    }

    func testSeedLibraryRowsPreservesExistingCustomization() {
        var visibility = HomeLibraryVisibility.default
        let seeds: [(libraryKey: String, kind: LibraryHomeRowKind)] = [
            ("acct:movies", .recentlyAdded),
            ("acct:movies", .hubs),
            ("acct:shows", .recentlyAdded)
        ]
        // First unmerge seeds everything on.
        XCTAssertTrue(visibility.seedLibraryRowsIfNeeded(seeds))
        // User pares it back to a single row.
        visibility.setLibraryRowEnabled(false, libraryKey: "acct:movies", kind: .hubs)
        visibility.setLibraryRowEnabled(false, libraryKey: "acct:shows", kind: .recentlyAdded)

        // A later merge on→off re-toggle must NOT re-seed over that choice.
        XCTAssertFalse(visibility.seedLibraryRowsIfNeeded(seeds), "Must not re-seed after the one-time seed")
        XCTAssertTrue(visibility.isLibraryRowEnabled("acct:movies", kind: .recentlyAdded))
        XCTAssertFalse(visibility.isLibraryRowEnabled("acct:movies", kind: .hubs))
        XCTAssertFalse(visibility.isLibraryRowEnabled("acct:shows", kind: .recentlyAdded))
    }

    func testSeedLibraryRowsDoesNotReSeedAfterUserTurnsEveryRowOff() {
        // Regression: an all-off selection must survive a merge re-toggle. An
        // emptiness check couldn't tell "customized to nothing on Home" from
        // "never seeded"; the explicit flag can.
        var visibility = HomeLibraryVisibility.default
        let seeds: [(libraryKey: String, kind: LibraryHomeRowKind)] = [
            ("acct:movies", .recentlyAdded),
            ("acct:shows", .recentlyAdded)
        ]
        XCTAssertTrue(visibility.seedLibraryRowsIfNeeded(seeds))
        // User turns EVERY per-library row off — a valid "only Shared rows" Home.
        visibility.setLibraryRowEnabled(false, libraryKey: "acct:movies", kind: .recentlyAdded)
        visibility.setLibraryRowEnabled(false, libraryKey: "acct:shows", kind: .recentlyAdded)
        XCTAssertTrue(visibility.enabledLibraryHomeRows.isEmpty)

        // Re-toggling merge off again must NOT re-enable everything.
        XCTAssertFalse(visibility.seedLibraryRowsIfNeeded(seeds))
        XCTAssertTrue(visibility.enabledLibraryHomeRows.isEmpty, "All-off choice must be preserved")
    }

    func testSeedLibraryRowsNoOpWhenNothingToSeedAndStaysUnseeded() {
        var visibility = HomeLibraryVisibility.default
        // Discovery not ready yet (no seeds) — must no-op AND stay unseeded so a
        // later attempt (once libraries load) can still seed.
        XCTAssertFalse(visibility.seedLibraryRowsIfNeeded([]))
        XCTAssertFalse(visibility.hasSeededLibraryRows)
        XCTAssertTrue(visibility.enabledLibraryHomeRows.isEmpty)

        XCTAssertTrue(visibility.seedLibraryRowsIfNeeded([("acct:movies", .recentlyAdded)]))
        XCTAssertTrue(visibility.hasSeededLibraryRows)
    }

    func testSeededFlagMigratesFromExistingOptedInRows() throws {
        // A blob predating the flag that already has opted-in rows must decode as
        // already-seeded, so a post-upgrade re-toggle doesn't re-seed over it.
        let legacyJSON = """
        {"mergeLibrariesOnHome":false,"enabledLibraryHomeRows":["acct:movies:recentlyAdded"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: legacyJSON)
        XCTAssertTrue(decoded.hasSeededLibraryRows, "Existing opted-in rows imply prior seeding")

        // A legacy blob with NO rows stays unseeded (can't tell first-run from
        // all-off for old data; safest is to allow one seed going forward).
        let emptyLegacy = """
        {"mergeLibrariesOnHome":true}
        """.data(using: .utf8)!
        let decodedEmpty = try JSONDecoder().decode(HomeLibraryVisibility.self, from: emptyLegacy)
        XCTAssertFalse(decodedEmpty.hasSeededLibraryRows)
    }
}
