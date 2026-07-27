import XCTest
import CoreModels
@testable import ProviderShare

/// Watch state on **share season containers**.
///
/// Share seasons are synthetic — built by grouping the assets table — so there is
/// no watch record under a season's own id, and `ShareWatchStateService.stamp`
/// deliberately skips containers. That left every share season permanently
/// unplayed.
///
/// Not cosmetic: the season chips showed no progress, and anything resolving
/// "which season is the viewer on" over the season containers always answered
/// "the first unwatched one" — Season 1 — however far into the show they were.
final class ShareSeasonWatchStateTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-season-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDurableStore() throws -> DurableLocalStateStore {
        try DurableLocalStateStore(secureStore: MemorySecureStore())
    }

    /// Local in-memory secure store (the equivalent in `ShareProviderWatchTests`
    /// is private to that file).
    private final class MemorySecureStore: SecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func setString(_ value: String, for key: String) throws {
            lock.lock(); storage[key] = value; lock.unlock()
        }

        func string(for key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return storage[key]
        }

        func readString(for key: String) throws -> String? { string(for: key) }

        func removeValue(for key: String) throws {
            lock.lock(); storage[key] = nil; lock.unlock()
        }
    }

    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(
                id: "share:nas.local/Media",
                name: "NAS",
                baseURL: URL(string: "smb://nas.local/Media")!,
                provider: .mediaShare
            ),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: ""
        )
    }

    private let seriesKey = ShareCatalogID.seriesKey(fromTitle: "Test Show")

    /// Two seasons of two episodes each.
    private func makeCatalog() async -> ShareCatalogStore {
        let catalog = ShareCatalogStore(accountKey: "season-watch", directory: makeTempDir())
        var assets: [CatalogAsset] = []
        for season in 1...2 {
            for episode in 1...2 {
                let rel = "TV/Test Show/S0\(season)/Test Show - s0\(season)e0\(episode).mkv"
                assets.append(
                    CatalogAsset(
                        relPath: rel, basename: "s0\(season)e0\(episode).mkv",
                        size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                        title: "Episode \(episode)", year: 2020,
                        seriesTitle: "Test Show", seriesKey: seriesKey,
                        season: season, episode: episode,
                        movieKey: nil, movieTitleKey: nil
                    )
                )
            }
        }
        await catalog.upsert(assets, scanID: 1)
        return catalog
    }

    private func makeWatchStore(_ durableStore: DurableLocalStateStore) -> ShareWatchStore {
        ShareWatchStore(
            localMediaContext: LocalMediaContext(
                accountID: "share:nas.local/Media",
                profileID: ProfileStore.defaultProfileID,
                profileNamespace: nil
            ),
            durableStore: durableStore
        )
    }

    private func fileID(season: Int, episode: Int) -> String {
        ShareCatalogID.file("TV/Test Show/S0\(season)/Test Show - s0\(season)e0\(episode).mkv")
    }

    private func seasons(
        catalog: ShareCatalogStore,
        durableStore: DurableLocalStateStore
    ) async throws -> [MediaItem] {
        let provider = ShareProvider(
            session: makeSession(),
            durableLocalStateStore: durableStore,
            catalogStore: catalog
        )
        return try await provider.children(of: ShareCatalogID.series(seriesKey))
    }

    func testFullyWatchedSeasonReportsPlayed() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()
        let watch = makeWatchStore(durableStore)
        for episode in 1...2 {
            await watch.setPlayed(true, itemID: fileID(season: 1, episode: episode), capturedAt: Date())
        }

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        let s1 = try XCTUnwrap(result.first { $0.seasonNumber == 1 })
        XCTAssertTrue(s1.isPlayed, "every episode watched must mark the season played")
        XCTAssertEqual(s1.playedPercentage, 1.0)
    }

    func testPartlyWatchedSeasonReportsProgressNotPlayed() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()
        let watch = makeWatchStore(durableStore)
        await watch.setPlayed(true, itemID: fileID(season: 2, episode: 1), capturedAt: Date())

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        let s2 = try XCTUnwrap(result.first { $0.seasonNumber == 2 })
        XCTAssertFalse(s2.isPlayed)
        XCTAssertEqual(try XCTUnwrap(s2.playedPercentage), 0.5, accuracy: 0.0001)
        XCTAssertTrue(s2.hasBeenPlayed)
    }

    func testUntouchedSeasonReportsNothing() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()
        let watch = makeWatchStore(durableStore)
        await watch.setPlayed(true, itemID: fileID(season: 1, episode: 1), capturedAt: Date())

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        let s2 = try XCTUnwrap(result.first { $0.seasonNumber == 2 })
        XCTAssertFalse(s2.isPlayed)
        XCTAssertFalse(s2.hasBeenPlayed)
        XCTAssertNil(s2.playedPercentage, "no progress must be nil, not a zeroed bar")
    }

    /// The bug this fixes, stated as behaviour: with S1 complete and S2 started,
    /// "which season is the viewer on" must answer S2, not Season 1.
    func testSeasonsResolveToTheOneBeingWatched() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()
        let watch = makeWatchStore(durableStore)
        for episode in 1...2 {
            await watch.setPlayed(true, itemID: fileID(season: 1, episode: episode), capturedAt: Date())
        }
        await watch.setResume(300, itemID: fileID(season: 2, episode: 1), capturedAt: Date(), duration: 3_000)

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        XCTAssertEqual(
            result.first { !$0.isPlayed }?.seasonNumber, 2,
            "S1 is complete, so the season being watched is S2 — not Season 1"
        )
    }

    /// One episode can exist as several files (a 1080p and a 4K rip). Episode ids
    /// are deliberately not folded together the way movie versions are, so
    /// counting raw files would report more episodes than the season has.
    func testMultipleFilesForOneEpisodeCountOnce() async throws {
        let durableStore = try makeDurableStore()
        let catalog = ShareCatalogStore(accountKey: "season-watch-versions", directory: makeTempDir())
        let base = "TV/Test Show/S01/Test Show - s01e01"
        await catalog.upsert(
            ["\(base) 1080p.mkv", "\(base) 2160p.mkv"].map { rel in
                CatalogAsset(
                    relPath: rel, basename: "s01e01.mkv",
                    size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                    title: "Episode 1", year: 2020,
                    seriesTitle: "Test Show", seriesKey: seriesKey,
                    season: 1, episode: 1,
                    movieKey: nil, movieTitleKey: nil
                )
            },
            scanID: 1
        )
        let watch = makeWatchStore(durableStore)
        // Watched only the 1080p rip — the episode has still been seen.
        await watch.setPlayed(true, itemID: ShareCatalogID.file("\(base) 1080p.mkv"), capturedAt: Date())

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        let s1 = try XCTUnwrap(result.first { $0.seasonNumber == 1 })
        XCTAssertTrue(
            s1.isPlayed,
            "two files of one episode are one episode — watching either completes the season"
        )
        XCTAssertEqual(s1.playedPercentage, 1.0)
    }

    /// A series with no watch history at all must not pay for a rollup or come
    /// back with invented state.
    func testNoHistoryLeavesSeasonsUntouched() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        XCTAssertEqual(result.count, 2)
        for season in result {
            XCTAssertFalse(season.isPlayed)
            XCTAssertFalse(season.hasBeenPlayed)
            XCTAssertNil(season.playedPercentage)
        }
    }
}
