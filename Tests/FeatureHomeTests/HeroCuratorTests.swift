import XCTest
import CoreModels
@testable import FeatureHome

/// Locks down `HeroCurator` composition: source ordering, concurrent async
/// sources, cross-source de-dup, `maxItems` cap, disabled-source skipping, and
/// the inert `.featured` (Seerr) seam.
final class HeroCuratorTests: XCTestCase {
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
        maxItems: Int = 8,
        randomKeys: Set<String> = []
    ) -> HeroSettings {
        HeroSettings(
            isEnabled: true,
            sources: sources,
            maxItems: maxItems,
            trailersEnabled: false,
            randomLibraryKeys: randomKeys,
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

    func testRandomProviderReceivesLibraryKeysAndContributes() async {
        let curator = HeroCurator()
        let expectedKeys: Set<String> = ["acct:lib1", "acct:lib2"]
        var seenKeys: Set<String>?
        let result = await curator.curate(
            settings: settings(sources: [.randomFromLibrary], randomKeys: expectedKeys),
            continueWatching: [],
            watchlist: [],
            randomProvider: { keys, _ in
                seenKeys = keys
                return [self.item("r1")]
            }
        )
        XCTAssertEqual(seenKeys, expectedKeys)
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
