import XCTest
import CoreModels
@testable import ProviderShare

final class ShareSearchCatalogAdapterTests: XCTestCase {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-search-adapter-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMissingCommittedStoreReturnsEmptyWithoutCreatingOne() async throws {
        let coordinator = ShareCatalogCoordinator()
        let adapter = ShareSearchCatalogAdapter(
            accountID: "missing",
            coordinator: coordinator
        )
        let page = try await adapter.searchCatalogPage(
            SearchCatalogPageRequest(
                libraryID: ShareCatalogID.moviesLibrary,
                kind: .movie
            )
        )
        XCTAssertTrue(page.records.isEmpty)
        XCTAssertEqual(page.totalCount, 0)
        let existing = await coordinator.existingStore(accountKey: "missing")
        XCTAssertNil(existing)
    }

    func testPagesMoviesSeriesAndEpisodesFromCommittedSnapshot() async throws {
        let store = ShareCatalogStore(accountKey: "share", directory: tempDirectory())
        let seriesKey = ShareCatalogID.seriesKey(fromTitle: "Example Show")
        await store.upsert([
            CatalogAsset(
                relPath: "Movies/Movie (2020).mkv",
                basename: "Movie (2020).mkv",
                size: 1_000,
                modifiedAt: Date(),
                kind: .movie,
                library: .movies,
                title: "Movie",
                year: 2020,
                seriesTitle: nil,
                seriesKey: nil,
                season: nil,
                episode: nil
            ),
            CatalogAsset(
                relPath: "TV Shows/Example Show/S01E01.mkv",
                basename: "S01E01.mkv",
                size: 1_000,
                modifiedAt: Date(),
                kind: .episode,
                library: .tv,
                title: "Pilot",
                year: 2020,
                seriesTitle: "Example Show",
                seriesKey: seriesKey,
                season: 1,
                episode: 1
            )
        ], scanID: 1)
        let coordinator = ShareCatalogCoordinator()
        await coordinator.registerExistingStore(store, accountKey: "share")
        let adapter = ShareSearchCatalogAdapter(
            accountID: "share",
            coordinator: coordinator
        )

        let movies = try await adapter.searchCatalogPage(
            SearchCatalogPageRequest(
                libraryID: ShareCatalogID.moviesLibrary,
                kind: .movie,
                limit: 1
            )
        )
        let series = try await adapter.searchCatalogPage(
            SearchCatalogPageRequest(
                libraryID: ShareCatalogID.tvLibrary,
                kind: .series,
                limit: 1
            )
        )
        let episodes = try await adapter.searchCatalogPage(
            SearchCatalogPageRequest(
                libraryID: ShareCatalogID.tvLibrary,
                kind: .episode,
                limit: 1
            )
        )

        XCTAssertEqual(movies.records.map(\.item.title), ["Movie"])
        XCTAssertEqual(series.records.map(\.item.title), ["Example Show"])
        XCTAssertEqual(episodes.records.map(\.item.title), ["Pilot"])
        XCTAssertEqual(episodes.records.first?.item.parentTitle, "Example Show")
    }
}
