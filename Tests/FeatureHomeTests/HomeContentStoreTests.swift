import XCTest
import CoreModels
@testable import FeatureHome

/// Locks down `HomeContentStore` — the per-profile snapshot that lets Home paint
/// the hero + Continue Watching instantly on the next launch. Covers round-trip,
/// bounding, per-profile (namespace) isolation, stale (`maxAge`) + empty misses,
/// and the in-memory / no-op variants.
final class HomeContentStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HomeContentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func content(cw: Int = 0, latest: Int = 0, watchlist: Int = 0) -> HomeViewModel.Content {
        HomeViewModel.Content(
            continueWatching: makeItems(cw),
            latest: makeItems(latest),
            watchlist: makeItems(watchlist),
            libraries: []
        )
    }

    func testMissWhenNothingPersisted() {
        let store = HomeContentStore(namespace: nil, directory: tempDir)
        XCTAssertNil(store.load())
    }

    func testSaveLoadRoundTrip() {
        let store = HomeContentStore(namespace: nil, directory: tempDir)
        store.save(content(cw: 3, latest: 5, watchlist: 2))
        let loaded = store.load()
        XCTAssertEqual(loaded?.continueWatching.count, 3)
        XCTAssertEqual(loaded?.latest.count, 5)
        XCTAssertEqual(loaded?.watchlist.count, 2)
        XCTAssertEqual(loaded?.continueWatching.first?.id, "i0")
    }

    func testSaveBoundsEachRow() {
        let store = HomeContentStore(namespace: nil, directory: tempDir, maxItemsPerRow: 10)
        store.save(content(cw: 50, latest: 40, watchlist: 25))
        let loaded = store.load()
        XCTAssertEqual(loaded?.continueWatching.count, 10, "Continue Watching is capped")
        XCTAssertEqual(loaded?.latest.count, 10, "Latest is capped")
        XCTAssertEqual(loaded?.watchlist.count, 10, "Watchlist is capped")
        // Bounding keeps the leading (most relevant) items.
        XCTAssertEqual(loaded?.continueWatching.first?.id, "i0")
        XCTAssertEqual(loaded?.continueWatching.last?.id, "i9")
    }

    func testEmptySnapshotIsNotUsed() {
        let store = HomeContentStore(namespace: nil, directory: tempDir)
        store.save(content()) // all rows empty
        XCTAssertNil(store.load(), "An empty snapshot is treated as a miss, not painted")
    }

    func testStaleSnapshotIsDroppedAndDeleted() {
        // Persist with a normal store, then read through one with maxAge == 0 so the
        // (freshly-written) file is considered stale. Same namespace/dir ⇒ same file.
        HomeContentStore(namespace: nil, directory: tempDir).save(content(cw: 2))
        let expiring = HomeContentStore(namespace: nil, directory: tempDir, maxAge: 0)
        XCTAssertNil(expiring.load(), "A snapshot older than maxAge is a miss")
        // And a subsequent normal read finds nothing (the stale file was removed).
        XCTAssertNil(HomeContentStore(namespace: nil, directory: tempDir).load())
    }

    func testNamespacesAreIsolated() {
        let primary = HomeContentStore(namespace: nil, directory: tempDir)
        let other = HomeContentStore(namespace: "profile-2", directory: tempDir)
        primary.save(content(cw: 1))
        other.save(content(watchlist: 7))
        XCTAssertEqual(primary.load()?.continueWatching.count, 1)
        XCTAssertEqual(primary.load()?.watchlist.count, 0)
        XCTAssertEqual(other.load()?.watchlist.count, 7)
        XCTAssertEqual(other.load()?.continueWatching.count, 0)
    }

    func testNilDirectoryIsNoOp() {
        let store = HomeContentStore(namespace: nil, directory: nil)
        store.save(content(cw: 3))
        XCTAssertNil(store.load())
    }

    func testInMemoryStoreRoundTripsAndTreatsEmptyAsMiss() {
        let store = InMemoryHomeContentStore(content(cw: 2))
        XCTAssertEqual(store.load()?.continueWatching.count, 2)
        store.save(content()) // empty
        XCTAssertNil(store.load(), "In-memory store also treats empty as a miss")
    }

    func testNoOpStoreNeverPersists() {
        let store = NoOpHomeContentStore()
        store.save(content(cw: 5))
        XCTAssertNil(store.load())
    }

    func testCuratedHeroPersistsAcrossInstancesForMatchingSettings() {
        let settings = HeroSettings(
            isEnabled: true,
            sources: [.featured],
            maxItems: 8,
            trailersEnabled: false,
            hideWatched: true,
            randomLibraryKeys: [],
            autoAdvance: true,
            autoAdvanceSeconds: 10
        )
        let key = HeroConfigurationKey(settings: settings)
        HomeContentStore(namespace: "hero", directory: tempDir)
            .saveHero(makeItems(3), for: key)

        let reopened = HomeContentStore(namespace: "hero", directory: tempDir)
        XCTAssertEqual(reopened.loadHero(for: key)?.map(\.id), ["i0", "i1", "i2"])
    }

    func testCuratedHeroDoesNotCrossSettingsOrProfile() {
        let featured = HeroSettings(
            isEnabled: true,
            sources: [.featured],
            maxItems: 8,
            trailersEnabled: false,
            hideWatched: true,
            randomLibraryKeys: [],
            autoAdvance: true,
            autoAdvanceSeconds: 10
        )
        var changed = featured
        changed.sources = [.continueWatching]
        let store = HomeContentStore(namespace: "hero-a", directory: tempDir)
        store.saveHero(makeItems(2), for: HeroConfigurationKey(settings: featured))

        XCTAssertNil(store.loadHero(for: HeroConfigurationKey(settings: changed)))
        XCTAssertNil(
            HomeContentStore(namespace: "hero-b", directory: tempDir)
                .loadHero(for: HeroConfigurationKey(settings: featured))
        )
    }

    func testChangingHeroSourcesInvalidatesTheLaunchSeed() {
        // The seed is now the whole curated set, not just its Featured bucket, so a
        // different source list describes a different carousel. Repainting the old
        // one would show titles from a source the viewer just switched off.
        let featuredOnly = HeroSettings(
            isEnabled: true,
            sources: [.featured],
            maxItems: 8,
            trailersEnabled: false,
            hideWatched: true,
            randomLibraryKeys: [],
            autoAdvance: true,
            autoAdvanceSeconds: 10
        )
        var mixed = featuredOnly
        mixed.sources = [
            .continueWatching,
            .featured,
            .recentlyAdded,
            .randomFromLibrary,
            .watchlist,
        ]
        mixed.randomLibraryKeys = ["server:movies"]
        let store = HomeContentStore(namespace: "mixed-hero", directory: tempDir)
        store.saveHero(makeItems(2), for: HeroConfigurationKey(settings: featuredOnly))

        XCTAssertNil(store.loadHero(for: HeroConfigurationKey(settings: mixed)))
    }

    func testPresentationSettingsDoNotInvalidateTheLaunchSeed() {
        // Trailers and auto-advance change how the carousel behaves, not which
        // titles can be in it, so flipping them must not cost a launch its hero.
        let settings = HeroSettings(
            isEnabled: true,
            sources: [.featured, .watchlist],
            maxItems: 8,
            trailersEnabled: false,
            hideWatched: true,
            randomLibraryKeys: [],
            autoAdvance: true,
            autoAdvanceSeconds: 10
        )
        var restyled = settings
        restyled.trailersEnabled = true
        restyled.autoAdvance = false
        restyled.autoAdvanceSeconds = 30
        let store = HomeContentStore(namespace: "restyled-hero", directory: tempDir)
        store.saveHero(makeItems(2), for: HeroConfigurationKey(settings: settings))

        XCTAssertEqual(
            store.loadHero(for: HeroConfigurationKey(settings: restyled))?.map(\.id),
            ["i0", "i1"]
        )
    }

    func testNarrowingTheRandomLibrarySelectionInvalidatesTheLaunchSeed() {
        let settings = HeroSettings(
            isEnabled: true,
            sources: [.randomFromLibrary],
            maxItems: 8,
            trailersEnabled: false,
            hideWatched: true,
            randomLibraryKeys: [],
            autoAdvance: true,
            autoAdvanceSeconds: 10
        )
        var narrowed = settings
        narrowed.randomLibraryKeys = ["server:movies"]
        let store = HomeContentStore(namespace: "random-hero", directory: tempDir)
        store.saveHero(makeItems(2), for: HeroConfigurationKey(settings: settings))

        XCTAssertNil(store.loadHero(for: HeroConfigurationKey(settings: narrowed)))
    }

    func testExpiredCuratedHeroIsDropped() {
        let settings = HeroSettings(
            isEnabled: true,
            sources: [.featured],
            maxItems: 8,
            trailersEnabled: false,
            hideWatched: false,
            randomLibraryKeys: [],
            autoAdvance: true,
            autoAdvanceSeconds: 10
        )
        let normal = HomeContentStore(namespace: "expired-hero", directory: tempDir)
        normal.saveHero(makeItems(1), for: HeroConfigurationKey(settings: settings))

        let expired = HomeContentStore(
            namespace: "expired-hero",
            directory: tempDir,
            heroMaxAge: 0
        )
        XCTAssertNil(expired.loadHero(for: HeroConfigurationKey(settings: settings)))
    }

    func testSerializedSnapshotNeverContainsLocalArtworkPath() throws {
        let path = "Private Library/Movies/Film/poster.jpg"
        let accountID = "share-account"
        let reference = try NetworkArtworkReference(
            accountID: accountID,
            credentialRevision: CredentialRevision(),
            catalogArtworkID: "art-home-snapshot",
            representation: RemoteFileRepresentation(
                size: 100,
                identity: RemoteFileIdentity(
                    kind: .modificationTime,
                    modifiedAt: Date(timeIntervalSince1970: 100)
                ),
                consistency: .changeDetecting
            ),
            sourceRevision: "opaque-revision"
        )
        let item = MediaItem(
            id: "private",
            title: "Private",
            kind: .movie,
            artworkSelections: [
                ArtworkSelection(
                    placement: .poster,
                    references: [.networkFile(reference)]
                )
            ]
        )
        let store = HomeContentStore(namespace: "privacy", directory: tempDir)
        store.save(
            HomeViewModel.Content(
                continueWatching: [item],
                latest: [],
                watchlist: [],
                libraries: []
            )
        )
        let data = try XCTUnwrap(
            try FileManager.default
                .contentsOfDirectory(
                    at: tempDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                .first
                .flatMap {
                    try FileManager.default.contentsOfDirectory(
                        at: $0,
                        includingPropertiesForKeys: nil
                    ).first
                }
                .map { try Data(contentsOf: $0) }
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains(path))
        XCTAssertFalse(text.contains("relativePath"))
        XCTAssertTrue(text.contains("catalogArtworkID"))
    }
}
