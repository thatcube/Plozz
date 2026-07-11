import XCTest
import CoreModels
@testable import FeatureHome

/// Locks down `HeroCurator` composition: source ordering, concurrent async
/// sources, cross-source de-dup, `maxItems` cap, disabled-source skipping, and
/// the inert `.featured` (Seerr) seam.
final class HeroCuratorTests: XCTestCase {
    private actor ArtworkCalls {
        private(set) var ids: [String] = []

        func record(_ id: String) {
            ids.append(id)
        }
    }

    private actor RandomCalls {
        private(set) var libraries: [HeroRandomLibrary] = []

        func record(_ libraries: [HeroRandomLibrary]) {
            self.libraries = libraries
        }
    }

    private func item(
        _ id: String,
        kind: MediaItemKind = .movie,
        hasHeroArtwork: Bool = true
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: id,
            kind: kind,
            posterURL: URL(string: "https://example.com/\(id)-poster.jpg"),
            backdropURL: hasHeroArtwork ? URL(string: "https://example.com/\(id).jpg") : nil
        )
    }

    private func settings(
        sources: [HeroSourceKind],
        maxItems: Int = 8
    ) -> HeroSettings {
        HeroSettings(
            isEnabled: true,
            sources: sources,
            maxItems: maxItems,
            trailersEnabled: false,
            randomLibraryKeys: [],
            autoAdvance: true,
            autoAdvanceSeconds: 10
        )
    }

    func testInactiveSettingsYieldNothing() async {
        let curator = HeroCurator()
        let result = await curator.curate(
            settings: settings(sources: []),
            continueWatching: [item("a")],
            watchlist: [item("b")]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testInterleavesSourcesInConfiguredOrder() async {
        let curator = HeroCurator()
        let result = await curator.curate(
            settings: settings(sources: [.continueWatching, .watchlist]),
            continueWatching: [item("c1"), item("c2")],
            watchlist: [item("w1"), item("w2")]
        )
        // Round-robin: cw[0], wl[0], cw[1], wl[1].
        XCTAssertEqual(result.map(\.id), ["c1", "w1", "c2", "w2"])
    }

    func testCapsAtMaxItems() async {
        let curator = HeroCurator()
        let result = await curator.curate(
            settings: settings(sources: [.continueWatching], maxItems: 2),
            continueWatching: [item("c1"), item("c2"), item("c3"), item("c4")],
            watchlist: []
        )
        XCTAssertEqual(result.map(\.id), ["c1", "c2"])
    }

    func testDeDupesSameItemAcrossSources() async {
        let curator = HeroCurator()
        // Same id appears in both continue watching and watchlist.
        let result = await curator.curate(
            settings: settings(sources: [.continueWatching, .watchlist]),
            continueWatching: [item("dup"), item("c2")],
            watchlist: [item("dup"), item("w2")]
        )
        XCTAssertEqual(result.map(\.id), ["dup", "c2", "w2"])
    }

    func testFeaturedSeamIsInertByDefault() async {
        let curator = HeroCurator()
        // Featured enabled but no provider injected → contributes nothing.
        let result = await curator.curate(
            settings: settings(sources: [.featured, .continueWatching]),
            continueWatching: [item("c1")],
            watchlist: []
        )
        XCTAssertEqual(result.map(\.id), ["c1"])
    }

    func testFeaturedProviderContributesWhenEnabled() async {
        let curator = HeroCurator()
        let result = await curator.curate(
            settings: settings(sources: [.featured, .continueWatching]),
            continueWatching: [item("c1")],
            watchlist: [],
            featuredProvider: { _ in [self.item("f1"), self.item("f2")] }
        )
        // Round-robin: f1, c1, f2.
        XCTAssertEqual(result.map(\.id), ["f1", "c1", "f2"])
    }

    func testRandomProviderReceivesResolvedLibrariesAndContributes() async {
        let curator = HeroCurator()
        let expectedLibraries = [
            HeroRandomLibrary(accountID: "acct", libraryID: "lib1", kind: .movie),
            HeroRandomLibrary(accountID: "acct", libraryID: "lib2", kind: .series)
        ]
        let calls = RandomCalls()
        let result = await curator.curate(
            settings: settings(sources: [.randomFromLibrary]),
            continueWatching: [],
            watchlist: [],
            randomLibraries: expectedLibraries,
            randomProvider: { libraries, _ in
                await calls.record(libraries)
                return [self.item("r1")]
            }
        )
        let seenLibraries = await calls.libraries
        XCTAssertEqual(seenLibraries, expectedLibraries)
        XCTAssertEqual(result.map(\.id), ["r1"])
    }

    func testDisabledSourceIsNotFetched() async {
        let curator = HeroCurator()
        var featuredCalled = false
        // Featured NOT in sources → provider must not be called.
        _ = await curator.curate(
            settings: settings(sources: [.continueWatching]),
            continueWatching: [item("c1")],
            watchlist: [],
            featuredProvider: { _ in featuredCalled = true; return [] }
        )
        XCTAssertFalse(featuredCalled)
    }

    func testExcludesItemsWithoutHeroArtwork() async {
        let curator = HeroCurator()
        let fallback = MediaItem(
            id: "fallback",
            title: "fallback",
            kind: .episode,
            fallbackArtworkURL: URL(string: "https://example.com/series.jpg")
        )
        let result = await curator.curate(
            settings: settings(sources: [.continueWatching]),
            continueWatching: [
                item("backdrop"),
                item("poster-only", hasHeroArtwork: false),
                fallback
            ],
            watchlist: []
        )

        XCTAssertEqual(result.map(\.id), ["backdrop", "fallback"])
    }

    func testIncludesRouterResolvedHeroArtwork() async {
        let curator = HeroCurator()
        let resolvedURL = URL(string: "https://example.com/resolved-hero.jpg")!
        let result = await curator.curate(
            settings: settings(sources: [.continueWatching]),
            continueWatching: [item("router", hasHeroArtwork: false)],
            watchlist: [],
            artworkProvider: { item in
                item.id == "router" ? resolvedURL : nil
            }
        )

        XCTAssertEqual(result.map(\.id), ["router"])
        XCTAssertEqual(result.first?.heroBackdropURL, resolvedURL)
    }

    func testArtworkResolutionStopsOnceSourceCanFillHero() async {
        let curator = HeroCurator()
        let calls = ArtworkCalls()
        let candidates = (1...10).map { item("router-\($0)", hasHeroArtwork: false) }

        let result = await curator.curate(
            settings: settings(sources: [.continueWatching], maxItems: 3),
            continueWatching: candidates,
            watchlist: [],
            artworkProvider: { item in
                await calls.record(item.id)
                return URL(string: "https://example.com/\(item.id)-hero.jpg")
            }
        )
        let resolvedIDs = await calls.ids

        XCTAssertEqual(result.map(\.id), ["router-1", "router-2", "router-3"])
        XCTAssertEqual(resolvedIDs, ["router-1", "router-2", "router-3"])
    }

    // MARK: - Synchronous seed (pop-in avoidance)

    func testCurateSyncUsesOnlyLibrarySourcesInOrder() {
        let curator = HeroCurator()
        // Featured + Random are async-only, so the sync seed treats them as empty
        // and interleaves just Continue Watching + Watchlist in configured order.
        let result = curator.curateSync(
            settings: settings(sources: [.featured, .continueWatching, .randomFromLibrary, .watchlist]),
            continueWatching: [item("c1"), item("c2")],
            watchlist: [item("w1")]
        )
        // Round-robin over the two populated sources: c1, w1, c2.
        XCTAssertEqual(result.map(\.id), ["c1", "w1", "c2"])
    }

    func testCurateSyncInactiveYieldsNothing() {
        let curator = HeroCurator()
        let result = curator.curateSync(
            settings: settings(sources: []),
            continueWatching: [item("c1")],
            watchlist: [item("w1")]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testCurateSyncRespectsMaxItems() {
        let curator = HeroCurator()
        let result = curator.curateSync(
            settings: settings(sources: [.continueWatching], maxItems: 2),
            continueWatching: [item("c1"), item("c2"), item("c3")],
            watchlist: []
        )
        XCTAssertEqual(result.map(\.id), ["c1", "c2"])
    }

    func testCurateSyncExcludesItemsWithoutHeroArtwork() {
        let curator = HeroCurator()
        let result = curator.curateSync(
            settings: settings(sources: [.continueWatching]),
            continueWatching: [item("art"), item("missing", hasHeroArtwork: false)],
            watchlist: []
        )

        XCTAssertEqual(result.map(\.id), ["art"])
    }
}

final class HomeHeroSlotStateTests: XCTestCase {
    func testAsyncOnlyHeroReservesPlaceholderUntilCurationCompletes() {
        XCTAssertEqual(
            HomeHeroSlotState.resolve(
                isConfigured: true,
                hasItems: false,
                recomputeComplete: false
            ),
            .placeholder
        )
    }

    func testAvailableSeedOrCuratedItemsShowContentImmediately() {
        XCTAssertEqual(
            HomeHeroSlotState.resolve(
                isConfigured: true,
                hasItems: true,
                recomputeComplete: false
            ),
            .content
        )
    }

    func testCompletedEmptyCurationRemovesPlaceholder() {
        XCTAssertEqual(
            HomeHeroSlotState.resolve(
                isConfigured: true,
                hasItems: false,
                recomputeComplete: true
            ),
            .hidden
        )
    }

    func testDisabledHeroNeverReservesSlot() {
        XCTAssertEqual(
            HomeHeroSlotState.resolve(
                isConfigured: false,
                hasItems: true,
                recomputeComplete: false
            ),
            .hidden
        )
    }
}

final class HeroRecomputeKeyTests: XCTestCase {
    private func settings(
        sources: [HeroSourceKind],
        trailersEnabled: Bool = false,
        autoAdvance: Bool = true,
        autoAdvanceSeconds: Int = 10
    ) -> HeroSettings {
        HeroSettings(
            isEnabled: true,
            sources: sources,
            maxItems: 8,
            trailersEnabled: trailersEnabled,
            randomLibraryKeys: [],
            autoAdvance: autoAdvance,
            autoAdvanceSeconds: autoAdvanceSeconds
        )
    }

    private func content(
        continueWatchingID: String = "cw",
        watchlistID: String = "wl"
    ) -> HomeViewModel.Content {
        HomeViewModel.Content(
            continueWatching: [
                MediaItem(id: continueWatchingID, title: continueWatchingID, kind: .movie)
            ],
            watchlist: [
                MediaItem(id: watchlistID, title: watchlistID, kind: .movie)
            ]
        )
    }

    func testViewOnlySettingsDoNotRestartCuration() {
        let original = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.randomFromLibrary]),
            randomLibraries: []
        )
        let changedPresentation = HeroRecomputeKey(
            content: content(),
            settings: settings(
                sources: [.randomFromLibrary],
                trailersEnabled: true,
                autoAdvance: false,
                autoAdvanceSeconds: 45
            ),
            randomLibraries: []
        )

        XCTAssertEqual(original, changedPresentation)
    }

    func testDisabledContentSourcesDoNotRestartRandomCuration() {
        let original = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.randomFromLibrary]),
            randomLibraries: []
        )
        let refreshedRows = HeroRecomputeKey(
            content: content(continueWatchingID: "new-cw", watchlistID: "new-wl"),
            settings: settings(sources: [.randomFromLibrary]),
            randomLibraries: []
        )

        XCTAssertEqual(original, refreshedRows)
    }

    func testEnabledContentSourceChangesRestartCuration() {
        let original = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.continueWatching]),
            randomLibraries: []
        )
        let refreshedRows = HeroRecomputeKey(
            content: content(continueWatchingID: "new-cw"),
            settings: settings(sources: [.continueWatching]),
            randomLibraries: []
        )

        XCTAssertNotEqual(original, refreshedRows)
    }

    func testRandomLibrariesOnlyParticipateWhenRandomSourceIsEnabled() {
        let library = HeroRandomLibrary(
            accountID: "account",
            libraryID: "movies",
            kind: .movie
        )
        let withoutRandom = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.watchlist]),
            randomLibraries: [library]
        )
        let withoutRandomOrLibrary = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.watchlist]),
            randomLibraries: []
        )
        let withRandom = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.randomFromLibrary]),
            randomLibraries: [library]
        )
        let withDifferentRandom = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.randomFromLibrary]),
            randomLibraries: []
        )

        XCTAssertEqual(withoutRandom, withoutRandomOrLibrary)
        XCTAssertNotEqual(withRandom, withDifferentRandom)
    }

    func testReappearanceDoesNotRerunCompletedCuration() {
        let key = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.randomFromLibrary]),
            randomLibraries: []
        )

        XCTAssertFalse(HeroRecomputePolicy.shouldRun(key: key, completedKey: key))
    }

    func testMissingOrChangedCompletionRunsCuration() {
        let original = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.randomFromLibrary]),
            randomLibraries: []
        )
        let changed = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.continueWatching]),
            randomLibraries: []
        )

        XCTAssertTrue(HeroRecomputePolicy.shouldRun(key: original, completedKey: nil))
        XCTAssertTrue(HeroRecomputePolicy.shouldRun(key: changed, completedKey: original))
    }
}

final class HeroRandomLibrarySelectionTests: XCTestCase {
    private func library(
        accountID: String,
        libraryID: String,
        kind: MediaItemKind
    ) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: accountID,
            accountName: accountID,
            serverName: accountID,
            providerKind: .jellyfin,
            library: MediaLibrary(id: libraryID, title: libraryID, kind: kind)
        )
    }

    private func settings(keys: Set<String>) -> HeroSettings {
        HeroSettings(
            isEnabled: true,
            sources: [.randomFromLibrary],
            maxItems: 8,
            trailersEnabled: false,
            randomLibraryKeys: keys,
            autoAdvance: true,
            autoAdvanceSeconds: 10
        )
    }

    func testEmptySelectionUsesOnlyVisibleLibraries() {
        let libraries = [
            library(accountID: "b", libraryID: "series", kind: .series),
            library(accountID: "a", libraryID: "movies", kind: .movie)
        ]

        let resolved = HeroRandomLibrarySelection.resolve(
            libraries,
            settings: settings(keys: []),
            isVisible: { $0 != "b:series" }
        )

        XCTAssertEqual(
            resolved,
            [HeroRandomLibrary(accountID: "a", libraryID: "movies", kind: .movie)]
        )
    }

    func testExplicitSelectionRemainsIndependentFromHomeVisibility() {
        let libraries = [
            library(accountID: "b", libraryID: "series", kind: .series),
            library(accountID: "a", libraryID: "movies", kind: .movie)
        ]

        let resolved = HeroRandomLibrarySelection.resolve(
            libraries,
            settings: settings(keys: ["b:series"]),
            isVisible: { _ in false }
        )

        XCTAssertEqual(
            resolved,
            [HeroRandomLibrary(accountID: "b", libraryID: "series", kind: .series)]
        )
    }
}
