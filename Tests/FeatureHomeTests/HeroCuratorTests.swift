import XCTest
import CoreModels
import FeatureHomeCore
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
        hasHeroArtwork: Bool = true,
        hasBeenPlayed: Bool = false,
        accountID: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: id,
            kind: kind,
            hasBeenPlayed: hasBeenPlayed,
            posterURL: URL(string: "https://example.com/\(id)-poster.jpg"),
            backdropURL: hasHeroArtwork ? URL(string: "https://example.com/\(id).jpg") : nil,
            sourceAccountID: accountID
        )
    }

    private func settings(
        sources: [HeroSourceKind],
        maxItems: Int = 8,
        hideWatched: Bool = true
    ) -> HeroSettings {
        HeroSettings(
            isEnabled: true,
            sources: sources,
            maxItems: maxItems,
            trailersEnabled: false,
            hideWatched: hideWatched,
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

    func testFinalDedupeCollapsesIdentityRevealedByHydration() {
        let sparseFeatured = MediaItem(
            id: "seer:series:277439",
            title: "Cape Fear",
            kind: .series,
            overview: "A storm is coming.",
            productionYear: 2026,
            genres: ["Drama"],
            backdropURL: URL(string: "https://example.com/featured.jpg"),
            ratings: [
                ExternalRating(source: .tmdb, value: 7.5, scale: .outOfTen)
            ]
        )
        let local = MediaItem(
            id: "series:cape-fear",
            title: "Cape Fear",
            kind: .series,
            backdropURL: URL(string: "https://example.com/local.jpg"),
            providerIDs: ["Tmdb": "277439"]
        )
        var hydratedFeatured = sparseFeatured
        hydratedFeatured.providerIDs["Tmdb"] = "277439"

        let result = HeroCurator().deduplicating([hydratedFeatured, local])

        XCTAssertEqual(result.map(\.id), ["seer:series:277439"])
        XCTAssertEqual(result[0].overview, "A storm is coming.")
        XCTAssertEqual(result[0].productionYear, 2026)
        XCTAssertEqual(result[0].genres, ["Drama"])
        XCTAssertEqual(result[0].ratings.map(\.source), [.tmdb])
    }

    func testFinalDedupeMergesIdentityBridgeTransitively() {
        let tmdbOnly = MediaItem(
            id: "tmdb-copy",
            title: "Bridge",
            kind: .series,
            providerIDs: ["Tmdb": "42"]
        )
        let imdbOnly = MediaItem(
            id: "imdb-copy",
            title: "Bridge",
            kind: .series,
            providerIDs: ["Imdb": "tt42"]
        )
        let bridge = MediaItem(
            id: "hydrated-copy",
            title: "Bridge",
            kind: .series,
            providerIDs: ["Tmdb": "42", "Imdb": "tt42"]
        )

        let result = HeroCurator().deduplicating([
            tmdbOnly,
            imdbOnly,
            bridge,
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].providerID(.tmdb), "42")
        XCTAssertEqual(result[0].providerID(.imdb), "tt42")
    }

    func testRawIDsAreScopedByAccountDuringDeduplication() async {
        let result = await HeroCurator().curate(
            settings: settings(sources: [.continueWatching, .watchlist]),
            continueWatching: [item("42", accountID: "server-a")],
            watchlist: [item("42", accountID: "server-b")]
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.sourceAccountID), ["server-a", "server-b"])
    }

    func testExternalIDsAreScopedByMediaKindDuringDeduplication() async {
        let movie = MediaItem(
            id: "seer:42",
            title: "Movie",
            kind: .movie,
            backdropURL: URL(string: "https://example.com/movie.jpg"),
            providerIDs: ["tmdb": "42"]
        )
        let series = MediaItem(
            id: "seer:42",
            title: "Series",
            kind: .series,
            backdropURL: URL(string: "https://example.com/series.jpg"),
            providerIDs: ["tmdb": "42"]
        )

        let result = await HeroCurator().curate(
            settings: settings(sources: [.continueWatching, .watchlist]),
            continueWatching: [movie],
            watchlist: [series]
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.kind), [.movie, .series])
    }

    func testDefaultHidesPreviouslyWatchedItemsFromEverySource() async {
        let result = await HeroCurator().curate(
            settings: settings(
                sources: [.featured, .continueWatching, .randomFromLibrary, .watchlist]
            ),
            continueWatching: [
                item("c-watched", kind: .episode, hasBeenPlayed: true),
                item("c-new", kind: .episode)
            ],
            watchlist: [
                item("w-watched", kind: .series, hasBeenPlayed: true),
                item("w-new", kind: .series)
            ],
            featuredProvider: { _ in
                [
                    self.item("f-watched", hasBeenPlayed: true),
                    self.item("f-new")
                ]
            },
            randomProvider: { _, _ in
                [
                    self.item("r-watched", kind: .series, hasBeenPlayed: true),
                    self.item("r-new", kind: .series)
                ]
            }
        )

        XCTAssertEqual(result.map(\.id), ["f-new", "c-new", "r-new", "w-new"])
    }

    func testDisablingFilterAllowsPreviouslyWatchedItems() async {
        let result = await HeroCurator().curate(
            settings: settings(
                sources: [.continueWatching],
                hideWatched: false
            ),
            continueWatching: [item("watched", hasBeenPlayed: true)],
            watchlist: []
        )

        XCTAssertEqual(result.map(\.id), ["watched"])
    }

    func testWatchedItemsAreFilteredBeforeArtworkResolution() async {
        let calls = ArtworkCalls()
        let result = await HeroCurator().curate(
            settings: settings(sources: [.watchlist]),
            continueWatching: [],
            watchlist: [
                item("watched", hasHeroArtwork: false, hasBeenPlayed: true),
                item("new")
            ],
            artworkProvider: { item in
                await calls.record(item.id)
                return URL(string: "https://example.com/\(item.id).jpg")
            }
        )

        XCTAssertEqual(result.map(\.id), ["new"])
        let resolvedIDs = await calls.ids
        XCTAssertTrue(resolvedIDs.isEmpty)
    }

    func testOptimisticWatchMutationFiltersFeaturedBeforeProviderConverges() async {
        let calls = ArtworkCalls()
        let featured = MediaItem(
            id: "tmdb-1",
            title: "Featured",
            kind: .movie,
            sources: [MediaSourceRef(accountID: "account", itemID: "library-1")]
        )
        let mutation = MediaItemMutation(
            itemIDs: ["library-1"],
            scopedItemIDs: ["account:library-1"],
            played: true
        )

        let result = await HeroCurator().curate(
            settings: settings(sources: [.featured]),
            continueWatching: [],
            watchlist: [],
            watchMutations: [mutation],
            featuredProvider: { _ in [featured] },
            artworkProvider: { item in
                await calls.record(item.id)
                return URL(string: "https://example.com/\(item.id).jpg")
            }
        )

        XCTAssertTrue(result.isEmpty)
        let resolvedIDs = await calls.ids
        XCTAssertTrue(resolvedIDs.isEmpty)
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

    func testCurationResultPersistsOnlyValidatedFeaturedBucket() async {
        let result = await HeroCurator().curateResult(
            settings: settings(
                sources: [
                    .featured,
                    .continueWatching,
                    .recentlyAdded,
                    .randomFromLibrary,
                    .watchlist,
                ]
            ),
            continueWatching: [item("cw")],
            watchlist: [item("watchlist")],
            recentlyAdded: [item("recent")],
            randomLibraries: [],
            featuredProvider: { _ in [self.item("featured")] },
            randomProvider: { _, _ in [self.item("random")] }
        )

        XCTAssertEqual(
            result.items.map(\.id),
            ["featured", "cw", "recent", "random", "watchlist"]
        )
        XCTAssertEqual(result.featuredItems.map(\.id), ["featured"])
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

    func testArtworkValidatorDropsCandidatesWhoseArtCannotLoad() async {
        let curator = HeroCurator()
        // Both have a non-nil backdrop URL, so presence-only eligibility would keep
        // them — but the injected validator reports "broken" art as unusable.
        let result = await curator.curate(
            settings: settings(sources: [.continueWatching]),
            continueWatching: [item("loads"), item("broken")],
            watchlist: [],
            artworkValidator: { urls in
                !urls.contains { $0.absoluteString.contains("broken") }
            }
        )

        XCTAssertEqual(result.map(\.id), ["loads"])
    }

    func testArtworkValidatorFallsBackToRouterWhenDirectArtIsBroken() async {
        let curator = HeroCurator()
        let rescued = URL(string: "https://cdn.example.com/rescued-hero.jpg")!
        // The item's own backdrop is broken, but the router supplies a usable one:
        // the item should be kept with the router art rather than dropped.
        let result = await curator.curate(
            settings: settings(sources: [.continueWatching]),
            continueWatching: [item("broken")],
            watchlist: [],
            artworkProvider: { _ in rescued },
            artworkValidator: { urls in urls.contains(rescued) }
        )

        XCTAssertEqual(result.map(\.id), ["broken"])
        XCTAssertEqual(result.first?.heroBackdropURL, rescued)
    }

    func testArtworkValidatorDropsCandidateWhenRouterArtAlsoUnusable() async {
        let curator = HeroCurator()
        let result = await curator.curate(
            settings: settings(sources: [.continueWatching]),
            continueWatching: [item("broken")],
            watchlist: [],
            artworkProvider: { _ in URL(string: "https://cdn.example.com/also-broken.jpg") },
            artworkValidator: { _ in false }
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testConcurrentArtworkValidationPreservesSourceOrder() async {
        let curator = HeroCurator()
        // More than one concurrency window, with broken items interleaved, so a
        // reordering bug (results consumed out of source order) would surface.
        let candidates = (0..<12).map { item("item-\($0)") }
        let result = await curator.curate(
            settings: settings(sources: [.continueWatching], maxItems: 6),
            continueWatching: candidates,
            watchlist: [],
            artworkValidator: { urls in
                // Odd-indexed titles have "broken" art and must be dropped.
                guard let url = urls.first else { return false }
                let name = url.deletingPathExtension().lastPathComponent // "item-3"
                guard let n = Int(name.dropFirst("item-".count)) else { return true }
                return n.isMultiple(of: 2)
            }
        )

        // The surviving even-indexed titles, in source order, capped at maxItems.
        XCTAssertEqual(result.map(\.id), ["item-0", "item-2", "item-4", "item-6", "item-8", "item-10"])
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
        // The source fills after the first bounded window, so art resolution never
        // scans all 10 candidates — concurrency over-checks by at most one window.
        XCTAssertLessThan(resolvedIDs.count, candidates.count)
        XCTAssertGreaterThanOrEqual(resolvedIDs.count, 3)
        XCTAssertEqual(Set(resolvedIDs).count, resolvedIDs.count, "no candidate resolved twice")
        XCTAssertTrue(
            Set(resolvedIDs).isSubset(of: Set((1...6).map { "router-\($0)" })),
            "resolution stays within the first bounded window"
        )
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

    func testCurateSyncHidesPreviouslyWatchedItems() {
        let result = HeroCurator().curateSync(
            settings: settings(sources: [.continueWatching]),
            continueWatching: [
                item("watched", hasBeenPlayed: true),
                item("new")
            ],
            watchlist: []
        )

        XCTAssertEqual(result.map(\.id), ["new"])
    }

    func testReconcileKeepsLoadedCandidatesButAppliesNewestWatchIntent() {
        let result = HeroCurator().reconcile(
            [item("watched"), item("new")],
            settings: settings(sources: [.featured]),
            watchMutations: [
                MediaItemMutation(itemIDs: ["watched"], played: true)
            ]
        )

        XCTAssertEqual(result.map(\.id), ["new"])
    }

    // MARK: One slide per show

    func testAResumableEpisodeAndItsWatchlistedSeriesShareOneSlide() async {
        // Continue Watching offers the episode you're mid-way through; Watchlist
        // offers the series. Scoping identity by `kind` kept them apart, so the same
        // show took two slides — once reading "Play S3, E1", once with a bookmark.
        let episode = MediaItem(
            id: "reacher-s3e1",
            title: "Reacher",
            kind: .episode,
            parentTitle: "Reacher",
            seasonNumber: 3,
            episodeNumber: 1,
            seriesID: "reacher-show",
            backdropURL: URL(string: "https://example.com/reacher-ep.jpg")
        )
        let series = MediaItem(
            id: "reacher-show",
            title: "Reacher",
            kind: .series,
            backdropURL: URL(string: "https://example.com/reacher.jpg")
        )
        let curated = await HeroCurator().curate(
            settings: settings(sources: [.continueWatching, .watchlist]),
            continueWatching: [episode],
            watchlist: [series]
        )
        XCTAssertEqual(curated.count, 1)
        XCTAssertEqual(curated.first?.id, "reacher-s3e1", "Continue Watching leads, so its episode wins the slide")
    }

    func testASeasonCollapsesIntoItsSeriesToo() async {
        let season = MediaItem(
            id: "silo-s2",
            title: "Silo",
            kind: .season,
            parentTitle: "Silo",
            seasonNumber: 2,
            seriesID: "silo-show",
            backdropURL: URL(string: "https://example.com/silo-s2.jpg")
        )
        let series = MediaItem(
            id: "silo-show",
            title: "Silo",
            kind: .series,
            backdropURL: URL(string: "https://example.com/silo.jpg")
        )
        let curated = await HeroCurator().curate(
            settings: settings(sources: [.watchlist, .continueWatching]),
            continueWatching: [series],
            watchlist: [season]
        )
        XCTAssertEqual(curated.count, 1)
    }

    func testAFilmAndASeriesSharingATitleStillGetTheirOwnSlides() async {
        // Folding a show's parts together must not fold *unrelated* titles together:
        // "Fargo" the film and "Fargo" the series are different things.
        let film = MediaItem(
            id: "fargo-film",
            title: "Fargo",
            kind: .movie,
            backdropURL: URL(string: "https://example.com/fargo-film.jpg")
        )
        let show = MediaItem(
            id: "fargo-series",
            title: "Fargo",
            kind: .series,
            backdropURL: URL(string: "https://example.com/fargo-series.jpg")
        )
        let curated = await HeroCurator().curate(
            settings: settings(sources: [.continueWatching, .watchlist]),
            continueWatching: [film],
            watchlist: [show]
        )
        XCTAssertEqual(curated.count, 2)
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
        autoAdvanceSeconds: Int = 10,
        hideWatched: Bool = true
    ) -> HeroSettings {
        HeroSettings(
            isEnabled: true,
            sources: sources,
            maxItems: 8,
            trailersEnabled: trailersEnabled,
            hideWatched: hideWatched,
            randomLibraryKeys: [],
            autoAdvance: autoAdvance,
            autoAdvanceSeconds: autoAdvanceSeconds
        )
    }

    private func content(
        continueWatchingID: String = "cw",
        watchlistID: String = "wl",
        hasBeenPlayed: Bool = false
    ) -> HomeViewModel.Content {
        HomeViewModel.Content(
            continueWatching: [
                MediaItem(
                    id: continueWatchingID,
                    title: continueWatchingID,
                    kind: .movie,
                    hasBeenPlayed: hasBeenPlayed
                )
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

    func testLiveHomeArrivalRestartsLocalHeroButNotFeaturedOnlyHero() {
        let localWaiting = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.continueWatching]),
            randomLibraries: [],
            awaitingLiveHome: true
        )
        let localReady = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.continueWatching]),
            randomLibraries: [],
            awaitingLiveHome: false
        )
        let featuredWaiting = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.featured]),
            randomLibraries: [],
            awaitingLiveHome: true
        )
        let featuredReady = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.featured]),
            randomLibraries: [],
            awaitingLiveHome: false
        )

        XCTAssertNotEqual(localWaiting, localReady)
        XCTAssertEqual(featuredWaiting, featuredReady)
    }

    func testRecentlyAddedChangesRestartCurationOnlyWhenEnabled() {
        let originalContent = HomeViewModel.Content(
            latest: [MediaItem(id: "old", title: "Old", kind: .movie)]
        )
        let refreshedContent = HomeViewModel.Content(
            latest: [MediaItem(id: "new", title: "New", kind: .movie)]
        )
        let enabledOriginal = HeroRecomputeKey(
            content: originalContent,
            settings: settings(sources: [.recentlyAdded]),
            randomLibraries: []
        )
        let enabledFresh = HeroRecomputeKey(
            content: refreshedContent,
            settings: settings(sources: [.recentlyAdded]),
            randomLibraries: []
        )
        let disabledOriginal = HeroRecomputeKey(
            content: originalContent,
            settings: settings(sources: [.featured]),
            randomLibraries: []
        )
        let disabledFresh = HeroRecomputeKey(
            content: refreshedContent,
            settings: settings(sources: [.featured]),
            randomLibraries: []
        )

        XCTAssertNotEqual(enabledOriginal, enabledFresh)
        XCTAssertEqual(disabledOriginal, disabledFresh)
    }

    func testWatchHistoryChangeRestartsEnabledSourceCuration() {
        let original = HeroRecomputeKey(
            content: content(hasBeenPlayed: false),
            settings: settings(sources: [.continueWatching]),
            randomLibraries: []
        )
        let watched = HeroRecomputeKey(
            content: content(hasBeenPlayed: true),
            settings: settings(sources: [.continueWatching]),
            randomLibraries: []
        )

        XCTAssertNotEqual(original, watched)
    }

    func testHideWatchedToggleRestartsCuration() {
        let hidden = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.continueWatching], hideWatched: true),
            randomLibraries: []
        )
        let shown = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.continueWatching], hideWatched: false),
            randomLibraries: []
        )

        XCTAssertNotEqual(hidden, shown)
    }

    func testExternalRefreshRestartsOnlyAsyncWatchFilteredSources() {
        let featured = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.featured], hideWatched: true),
            randomLibraries: [],
            externalRefreshRevision: 1
        )
        let refreshedFeatured = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.featured], hideWatched: true),
            randomLibraries: [],
            externalRefreshRevision: 2
        )
        let filterDisabled = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.featured], hideWatched: false),
            randomLibraries: [],
            externalRefreshRevision: 1
        )
        let refreshedFilterDisabled = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.featured], hideWatched: false),
            randomLibraries: [],
            externalRefreshRevision: 2
        )

        XCTAssertNotEqual(featured, refreshedFeatured)
        XCTAssertEqual(filterDisabled, refreshedFilterDisabled)
    }

    func testSourceGrowthRestartsOnlyWatchFilteredRowSources() {
        let coldItem = MediaItem(
            id: "item",
            title: "Item",
            kind: .movie
        )
        let enrichedItem = MediaItem(
            id: "item",
            title: "Item",
            kind: .movie,
            sources: [MediaSourceRef(accountID: "account", itemID: "copy")]
        )
        let coldContent = HomeViewModel.Content(continueWatching: [coldItem])
        let enrichedContent = HomeViewModel.Content(continueWatching: [enrichedItem])

        let filteredCold = HeroRecomputeKey(
            content: coldContent,
            settings: settings(sources: [.continueWatching], hideWatched: true),
            randomLibraries: []
        )
        let filteredEnriched = HeroRecomputeKey(
            content: enrichedContent,
            settings: settings(sources: [.continueWatching], hideWatched: true),
            randomLibraries: []
        )
        let unfilteredCold = HeroRecomputeKey(
            content: coldContent,
            settings: settings(sources: [.continueWatching], hideWatched: false),
            randomLibraries: []
        )
        let unfilteredEnriched = HeroRecomputeKey(
            content: enrichedContent,
            settings: settings(sources: [.continueWatching], hideWatched: false),
            randomLibraries: []
        )

        XCTAssertNotEqual(filteredCold, filteredEnriched)
        XCTAssertEqual(unfilteredCold, unfilteredEnriched)
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

    func testExternalWatchRefreshCanReuseLoadedCandidateSet() {
        let original = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.featured]),
            randomLibraries: [],
            externalRefreshRevision: 1
        )
        let refreshing = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.featured]),
            randomLibraries: [],
            externalRefreshRevision: 2
        )
        let structurallyChanged = HeroRecomputeKey(
            content: content(),
            settings: settings(sources: [.watchlist]),
            randomLibraries: [],
            externalRefreshRevision: 2
        )

        XCTAssertNotEqual(original, refreshing)
        XCTAssertTrue(original.matchesIgnoringExternalRefresh(refreshing))
        XCTAssertFalse(original.matchesIgnoringExternalRefresh(structurallyChanged))
    }
}

@MainActor
final class HomeHeroRuntimeStateTests: XCTestCase {
    func testLoadedHeroStateSurvivesViewReconstructionThroughSharedOwner() {
        let runtime = HomeHeroRuntimeState()
        runtime.items = [
            MediaItem(id: "featured", title: "Featured", kind: .movie)
        ]
        runtime.hasHydratedDurableMutations = true

        let reconstructedViewOwner = runtime

        XCTAssertEqual(reconstructedViewOwner.items.map(\.id), ["featured"])
        XCTAssertTrue(reconstructedViewOwner.hasHydratedDurableMutations)
    }

    func testRegisterWatchMutationCoalescesRepeatedTogglesOfSameTarget() {
        let runtime = HomeHeroRuntimeState()
        runtime.registerWatchMutation(MediaItemMutation(itemIDs: ["a"], played: true))
        runtime.registerWatchMutation(MediaItemMutation(itemIDs: ["b"], played: true))
        // Re-toggling "a" must collapse onto the newest intent, not append.
        runtime.registerWatchMutation(MediaItemMutation(itemIDs: ["a"], played: false))

        XCTAssertEqual(runtime.watchMutations.count, 2)
        let a = runtime.watchMutations.first { $0.itemIDs == ["a"] }
        XCTAssertEqual(a?.played, false)
        // The newest intent for "a" is last (append-after-remove), preserving order.
        XCTAssertEqual(runtime.watchMutations.last?.itemIDs, ["a"])
    }

    func testRegisterWatchMutationScopesCoalesceByFullTargetSet() {
        let runtime = HomeHeroRuntimeState()
        runtime.registerWatchMutation(
            MediaItemMutation(itemIDs: ["a"], scopedItemIDs: ["acct:a"], played: true)
        )
        // Same bare id but a different scoped set is a distinct physical target.
        runtime.registerWatchMutation(
            MediaItemMutation(itemIDs: ["a"], scopedItemIDs: ["other:a"], played: true)
        )

        XCTAssertEqual(runtime.watchMutations.count, 2)
    }

    func testRegisterWatchMutationCapsSessionOverlay() {
        let runtime = HomeHeroRuntimeState()
        let overflow = HomeHeroRuntimeState.maxSessionWatchMutations + 20
        for index in 0..<overflow {
            runtime.registerWatchMutation(
                MediaItemMutation(itemIDs: ["item-\(index)"], played: true)
            )
        }

        XCTAssertEqual(
            runtime.watchMutations.count,
            HomeHeroRuntimeState.maxSessionWatchMutations
        )
        // Oldest evicted, newest retained.
        XCTAssertFalse(runtime.watchMutations.contains { $0.itemIDs == ["item-0"] })
        XCTAssertTrue(
            runtime.watchMutations.contains { $0.itemIDs == ["item-\(overflow - 1)"] }
        )
    }
}

@MainActor
final class HomeHeroDisplayResolverTests: XCTestCase {
    private func settings(
        sources: [HeroSourceKind] = [.continueWatching],
        hideWatched: Bool
    ) -> HeroSettings {
        HeroSettings(
            isEnabled: true,
            sources: sources,
            maxItems: 8,
            trailersEnabled: false,
            hideWatched: hideWatched,
            randomLibraryKeys: [],
            autoAdvance: true,
            autoAdvanceSeconds: 10
        )
    }

    private func key(_ settings: HeroSettings, content: HomeViewModel.Content) -> HeroRecomputeKey {
        HeroRecomputeKey(content: content, settings: settings, randomLibraries: [])
    }

    private func item(_ id: String, hasBeenPlayed: Bool = false) -> MediaItem {
        MediaItem(
            id: id,
            title: id,
            kind: .movie,
            hasBeenPlayed: hasBeenPlayed,
            backdropURL: URL(string: "https://example.com/\(id).jpg")
        )
    }

    private func allSourceOrders() -> [[HeroSourceKind]] {
        var result: [[HeroSourceKind]] = []
        func appendOrders(
            prefix: [HeroSourceKind],
            remaining: [HeroSourceKind]
        ) {
            if !prefix.isEmpty { result.append(prefix) }
            for index in remaining.indices {
                var nextRemaining = remaining
                let next = nextRemaining.remove(at: index)
                appendOrders(
                    prefix: prefix + [next],
                    remaining: nextRemaining
                )
            }
        }
        appendOrders(prefix: [], remaining: HeroSourceKind.allCases)
        return result
    }

    func testReconcilesRetainedItemsWhenKeyMatchesAndDropsNewlyWatched() {
        let settings = settings(hideWatched: true)
        let content = HomeViewModel.Content(continueWatching: [item("a"), item("b")])
        let recomputeKey = key(settings, content: content)
        let runtime = HomeHeroRuntimeState()
        runtime.items = [item("a"), item("b", hasBeenPlayed: true)]
        runtime.completedKey = recomputeKey
        runtime.hasHydratedDurableMutations = true

        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: recomputeKey,
            settings: settings,
            continueWatching: content.continueWatching,
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertEqual(resolved.map(\.id), ["a"])
    }

    func testWaitsForCompletedCurationInsteadOfShowingPartialLocalSeed() {
        let settings = settings(hideWatched: false)
        let content = HomeViewModel.Content(continueWatching: [item("seed")])
        let runtime = HomeHeroRuntimeState()

        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: key(settings, content: content),
            settings: settings,
            continueWatching: content.continueWatching,
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertTrue(resolved.isEmpty)
    }

    func testUsesMatchingCachedCuratedHeroBeforeAsyncRecomputeCompletes() {
        let settings = settings(sources: [.featured], hideWatched: false)
        let content = HomeViewModel.Content()
        let runtime = HomeHeroRuntimeState()
        runtime.cachedKey = HomeHeroCacheKey(settings: settings)
        runtime.cachedItems = [item("cached-featured")]

        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: key(settings, content: content),
            settings: settings,
            continueWatching: [],
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertEqual(resolved.map(\.id), ["cached-featured"])
    }

    func testLaunchSourceMatrixNeverUsesCachedContinueWatching() {
        let cachedFeatured = item("cached-featured")
        let staleContinueWatching = item("stale-cw")
        let cachedWatchlist = item("cached-watchlist")
        let cachedRecent = item("cached-recent")
        let cachedContent = HomeViewModel.Content(
            continueWatching: [staleContinueWatching],
            latest: [cachedRecent],
            watchlist: [cachedWatchlist]
        )
        let launchContent = HomeHeroLaunchPolicy.content(
            cachedContent,
            awaitingLiveContinueWatching: true
        )
        XCTAssertTrue(launchContent.continueWatching.isEmpty)
        XCTAssertEqual(launchContent.watchlist.map(\.id), ["cached-watchlist"])
        XCTAssertEqual(launchContent.latest.map(\.id), ["cached-recent"])

        let cases: [([HeroSourceKind], [String])] = [
            ([.featured], ["cached-featured"]),
            ([.continueWatching], []),
            ([.featured, .continueWatching], []),
            ([.continueWatching, .featured], []),
            ([.featured, .watchlist], []),
            ([.watchlist, .featured], []),
            ([.featured, .recentlyAdded], []),
            ([.randomFromLibrary], []),
            (
                [
                    .featured,
                    .continueWatching,
                    .recentlyAdded,
                    .randomFromLibrary,
                    .watchlist,
                ],
                []
            ),
        ]

        for (sources, expected) in cases {
            let settings = settings(sources: sources, hideWatched: false)
            let runtime = HomeHeroRuntimeState()
            if sources.contains(.featured) {
                runtime.cachedKey = HomeHeroCacheKey(settings: settings)
                runtime.cachedItems = [cachedFeatured]
            }
            let resolved = HomeHeroDisplayResolver.resolve(
                runtime: runtime,
                key: key(settings, content: launchContent),
                settings: settings,
                continueWatching: launchContent.continueWatching,
                watchlist: launchContent.watchlist,
                recentlyAdded: launchContent.latest,
                curator: HeroCurator()
            )

            XCTAssertEqual(resolved.map(\.id), expected, "sources: \(sources)")
            XCTAssertFalse(
                resolved.contains(where: { $0.id == "stale-cw" }),
                "sources: \(sources)"
            )
        }
    }

    func testFreshContinueWatchingJoinsHeroAfterLiveAggregate() {
        let settings = settings(
            sources: [.featured, .continueWatching],
            hideWatched: false
        )
        let liveContent = HomeViewModel.Content(
            continueWatching: [item("fresh-cw")]
        )
        let runtime = HomeHeroRuntimeState()
        runtime.items = [item("cached-featured"), item("fresh-cw")]
        runtime.completedKey = key(settings, content: liveContent)

        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: key(settings, content: liveContent),
            settings: settings,
            continueWatching: liveContent.continueWatching,
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertEqual(resolved.map(\.id), ["cached-featured", "fresh-cw"])
    }

    func testEveryOrderedSourceConfigurationUsesOnlyFreshContinueWatching() {
        let cachedFeatured = item("featured")
        let stale = HomeViewModel.Content(
            continueWatching: [item("stale-cw")],
            latest: [item("recent")],
            watchlist: [item("watchlist")]
        )
        let launch = HomeHeroLaunchPolicy.content(
            stale,
            awaitingLiveContinueWatching: true
        )
        var live = launch
        live.continueWatching = [item("fresh-cw")]

        for sources in allSourceOrders() {
            let settings = settings(sources: sources, hideWatched: false)
            let runtime = HomeHeroRuntimeState()
            if sources.contains(.featured) {
                runtime.cachedKey = HomeHeroCacheKey(settings: settings)
                runtime.cachedItems = [cachedFeatured]
            }

            let launchResolved = HomeHeroDisplayResolver.resolve(
                runtime: runtime,
                key: key(settings, content: launch),
                settings: settings,
                continueWatching: launch.continueWatching,
                watchlist: launch.watchlist,
                recentlyAdded: launch.latest,
                curator: HeroCurator()
            )
            let expectedLaunch = sources == [.featured] ? ["featured"] : []
            XCTAssertEqual(
                launchResolved.map(\.id),
                expectedLaunch,
                "cached launch sources: \(sources)"
            )
            XCTAssertFalse(launchResolved.contains { $0.id == "stale-cw" })

            let expectedLive = sources.compactMap { source -> String? in
                switch source {
                case .featured: return "featured"
                case .continueWatching: return "fresh-cw"
                case .recentlyAdded: return "recent"
                case .randomFromLibrary: return "random"
                case .watchlist: return "watchlist"
                }
            }
            runtime.items = expectedLive.map { item($0) }
            runtime.completedKey = key(settings, content: live)
            let liveResolved = HomeHeroDisplayResolver.resolve(
                runtime: runtime,
                key: key(settings, content: live),
                settings: settings,
                continueWatching: live.continueWatching,
                watchlist: live.watchlist,
                recentlyAdded: live.latest,
                curator: HeroCurator()
            )
            XCTAssertEqual(
                liveResolved.map(\.id),
                expectedLive,
                "live sources: \(sources)"
            )
        }
    }

    func testIgnoresCachedCuratedHeroWhenSourceSettingsChanged() {
        let cachedSettings = settings(sources: [.featured], hideWatched: false)
        let currentSettings = settings(sources: [.continueWatching], hideWatched: false)
        let content = HomeViewModel.Content(continueWatching: [item("live-seed")])
        let runtime = HomeHeroRuntimeState()
        runtime.cachedKey = HomeHeroCacheKey(settings: cachedSettings)
        runtime.cachedItems = [item("stale-featured")]

        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: key(currentSettings, content: content),
            settings: currentSettings,
            continueWatching: content.continueWatching,
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertTrue(resolved.isEmpty)
    }

    func testSuppressesSeedUntilDurableMutationsHydrateWhenHidingWatched() {
        let settings = settings(hideWatched: true)
        let content = HomeViewModel.Content(continueWatching: [item("seed")])
        let runtime = HomeHeroRuntimeState()
        // hasHydratedDurableMutations defaults false → seed must stay hidden so a
        // title an offline mutation already marked watched can't flash in.

        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: key(settings, content: content),
            settings: settings,
            continueWatching: content.continueWatching,
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertTrue(resolved.isEmpty)
    }

    func testALoadedHeroKeepsRenderingWhileTheNextCurationRuns() {
        // The whole point: Home re-curates for reasons the viewer never asked for
        // (a silent re-aggregation, a warmed identity index, a share scan), and a
        // full re-curation takes seconds. Dropping to the placeholder for each of
        // those is what made the hero look like it reloaded constantly.
        let settings = settings(
            sources: [.continueWatching, .randomFromLibrary],
            hideWatched: false
        )
        let loadedContent = HomeViewModel.Content(
            continueWatching: [item("a")]
        )
        let runtime = HomeHeroRuntimeState()
        runtime.items = [item("a"), item("random")]
        runtime.completedKey = key(settings, content: loadedContent)

        // Home republished with different content — a brand-new recompute key,
        // not merely an external watch-history refresh.
        let republished = HomeViewModel.Content(
            continueWatching: [item("a"), item("b")]
        )
        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: key(settings, content: republished),
            settings: settings,
            continueWatching: republished.continueWatching,
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertEqual(resolved.map(\.id), ["a", "random"])
    }

    func testAWatchedTitleStillLeavesARetainedHero() {
        let settings = settings(hideWatched: true)
        let loadedContent = HomeViewModel.Content(continueWatching: [item("a")])
        let runtime = HomeHeroRuntimeState()
        runtime.items = [item("a"), item("b", hasBeenPlayed: true)]
        runtime.completedKey = key(settings, content: loadedContent)
        runtime.hasHydratedDurableMutations = true

        let republished = HomeViewModel.Content(
            continueWatching: [item("a"), item("c")]
        )
        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: key(settings, content: republished),
            settings: settings,
            continueWatching: republished.continueWatching,
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertEqual(resolved.map(\.id), ["a"])
    }

    func testChangingTheHeroSConfigurationRetiresTheLoadedSetAtOnce() {
        // A configuration change is a direct instruction, not the world moving.
        let loadedSettings = settings(
            sources: [.continueWatching, .randomFromLibrary],
            hideWatched: false
        )
        let content = HomeViewModel.Content(continueWatching: [item("a")])
        let runtime = HomeHeroRuntimeState()
        runtime.items = [item("a"), item("random")]
        runtime.completedKey = key(loadedSettings, content: content)

        let chosen = settings(sources: [.continueWatching], hideWatched: false)
        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: key(chosen, content: content),
            settings: chosen,
            continueWatching: content.continueWatching,
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertTrue(resolved.isEmpty)
    }

    func testALoadedHeroSurvivesArrivingAtTheCachedLaunchSnapshotAgain() {
        // `awaitingLiveHome` flips the key, but a hero that already curated has
        // nothing to protect — the fresh curation folds into it.
        let settings = settings(hideWatched: false)
        let content = HomeViewModel.Content(continueWatching: [item("a")])
        let runtime = HomeHeroRuntimeState()
        runtime.items = [item("a")]
        runtime.completedKey = HeroRecomputeKey(
            content: content,
            settings: settings,
            randomLibraries: []
        )

        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime,
            key: HeroRecomputeKey(
                content: content,
                settings: settings,
                randomLibraries: [],
                awaitingLiveHome: true
            ),
            settings: settings,
            continueWatching: content.continueWatching,
            watchlist: [],
            curator: HeroCurator()
        )

        XCTAssertEqual(resolved.map(\.id), ["a"])
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
