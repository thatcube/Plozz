import XCTest
@testable import ProviderShare
import CoreModels
import CoreNetworking
import MediaTransportCore

/// Batch 12 (E5 valid portion + E7) coverage. Proves `ShareProvider` is a thin
/// facade over injected capabilities: catalog reads flow through
/// `any ShareCatalogReading`, watch-state through `ShareWatchStateService`, and
/// rescan/activity through `any ShareCatalogCoordinating` — with no dependency on
/// the concrete `ShareCatalogStore`. Also exercises the extracted watch-state
/// service directly, and a source-inspection gate confirming the facade never
/// names the concrete store.
final class ShareProviderCapabilityTests: XCTestCase {

    // MARK: Fakes

    /// Fake read-only catalog capability. Every method is answered from injected
    /// values; there is no SQLite store behind it.
    private final class FakeCatalogReader: ShareCatalogReading, @unchecked Sendable {
        var latestItems: [MediaItem] = []
        var searchItems: [MediaItem] = []
        var movieItems: [MediaItem] = []
        var seriesItems: [MediaItem] = []
        var indexedItem: [String: MediaItem] = [:]
        var canonicalMap: [String: String] = [:]
        var aliasMap: [String: String] = [:]

        func libraryCounts() async -> (movies: Int, tvSeries: Int, animeSeries: Int) {
            (movieItems.count, seriesItems.count, 0)
        }
        func latest(limit: Int) async -> [MediaItem] { Array(latestItems.prefix(limit)) }
        func search(query: String, limit: Int) async -> [MediaItem] { Array(searchItems.prefix(limit)) }
        func movies(offset: Int, limit: Int) async -> [MediaItem] { movieItems }
        func series(in library: CatalogLibrary, offset: Int, limit: Int) async -> [MediaItem] { seriesItems }
        func movieCount() async -> Int { movieItems.count }
        func seriesCount(in library: CatalogLibrary) async -> Int { seriesItems.count }
        func seasons(seriesKey: String) async -> [MediaItem] { [] }
        func episodes(seriesKey: String, season: Int) async -> [MediaItem] { [] }
        func item(id: String) async -> MediaItem? { indexedItem[id] }
        func defaultMovieRelPath(forKey key: String) async -> String? { nil }
        func canonicalItemID(_ id: String) async -> String { canonicalMap[id] ?? id }
        func watchStateAliases(for itemIDs: [String]) async -> [String: String] {
            var result: [String: String] = [:]
            for id in itemIDs { result[id] = aliasMap[id] ?? id }
            return result
        }
        func containsFileAsset(id: String) async -> Bool { false }
    }

    /// Fake coordinating capability. Records rescan/enrich/activity calls and vends
    /// a supplied reader — no concrete `ShareCatalogCoordinator`/store is created.
    private final class FakeCatalogCoordinator: ShareCatalogCoordinating, @unchecked Sendable {
        let reader: FakeCatalogReader
        private(set) var catalogReaderRequests: [String] = []
        private(set) var rescans: [String] = []
        private(set) var enrichCalls: [String] = []
        private(set) var activityCalls: [String] = []

        init(reader: FakeCatalogReader) { self.reader = reader }

        func catalogReader(
            accountKey: String,
            displayName: String,
            credentialRevision: CredentialRevision,
            sessionFactory: @escaping ShareTransportSessionFactory
        ) async -> any ShareCatalogReading {
            catalogReaderRequests.append(accountKey)
            return reader
        }
        func rescan(accountKey: String) async { rescans.append(accountKey) }
        func enrichItem(accountKey: String, itemID: String) async { enrichCalls.append(itemID) }
        func noteInteractiveActivity(accountKey: String) async { activityCalls.append(accountKey) }
    }

    private func makeSession() -> UserSession {
        let server = MediaServer(
            id: "share:nas.local/Media",
            name: "NAS",
            baseURL: URL(string: "smb://nas.local/Media")!,
            provider: .mediaShare
        )
        return UserSession(
            server: server,
            userID: "guest",
            userName: "guest",
            deviceID: "test-device",
            accessToken: ""
        )
    }

    // MARK: Provider-from-capabilities

    /// The provider resolves its catalog reads entirely through the injected
    /// coordinating capability's `catalogReader` — no concrete store constructed.
    func testProviderResolvesLatestThroughFakeCapability() async throws {
        let reader = FakeCatalogReader()
        reader.latestItems = [
            MediaItem(id: "f:a.mkv", title: "Alpha", kind: .movie),
            MediaItem(id: "f:b.mkv", title: "Beta", kind: .movie)
        ]
        let coordinator = FakeCatalogCoordinator(reader: reader)
        let provider = ShareProvider(
            session: makeSession(),
            catalogCoordinator: coordinator
        )

        let latest = try await provider.latest(limit: 10)

        XCTAssertEqual(latest.map(\.title), ["Alpha", "Beta"])
        XCTAssertFalse(coordinator.catalogReaderRequests.isEmpty)
        XCTAssertTrue(coordinator.catalogReaderRequests.allSatisfy { $0 == "share:nas.local/Media" })
    }

    func testProviderSearchRoutesThroughReadCapability() async throws {
        let reader = FakeCatalogReader()
        reader.searchItems = [MediaItem(id: "f:c.mkv", title: "Gamma", kind: .movie)]
        let coordinator = FakeCatalogCoordinator(reader: reader)
        let provider = ShareProvider(session: makeSession(), catalogCoordinator: coordinator)

        let hits = try await provider.search(query: "gam", limit: 5)

        XCTAssertEqual(hits.map(\.title), ["Gamma"])
    }

    /// `rescan()` touches the catalog (registering the reader) and then routes to
    /// the coordinating capability's `rescan` — never a downcast to a concrete type.
    func testRescanRoutesThroughCoordinatingCapability() async throws {
        let coordinator = FakeCatalogCoordinator(reader: FakeCatalogReader())
        let provider = ShareProvider(session: makeSession(), catalogCoordinator: coordinator)

        await provider.rescan()

        XCTAssertEqual(coordinator.rescans, ["share:nas.local/Media"])
        XCTAssertEqual(coordinator.catalogReaderRequests, ["share:nas.local/Media"])
    }

    func testInteractiveActivityRoutesThroughCoordinatingCapability() async throws {
        let coordinator = FakeCatalogCoordinator(reader: FakeCatalogReader())
        let provider = ShareProvider(session: makeSession(), catalogCoordinator: coordinator)

        await provider.noteInteractiveBrowseActivity()

        XCTAssertEqual(coordinator.activityCalls, ["share:nas.local/Media"])
    }

    // MARK: ShareWatchStateService direct

    private func makeWatchStore() -> ShareWatchStore {
        ShareWatchStore(
            localMediaContext: LocalMediaContext(
                accountID: "share:nas.local/Media",
                profileID: ProfileStore.defaultProfileID,
                profileNamespace: nil
            ),
            durableStore: nil
        )
    }

    func testWatchStateServiceStampsResumeState() async throws {
        let reader = FakeCatalogReader()
        let watchStore = makeWatchStore()
        await watchStore.setResume(120, itemID: "f:m.mkv", capturedAt: Date(), duration: 600)
        let service = ShareWatchStateService(
            watchStore: watchStore,
            accountID: "share:nas.local/Media",
            catalog: { reader }
        )

        let stamped = await service.stamp(MediaItem(id: "f:m.mkv", title: "Movie", kind: .movie))

        XCTAssertEqual(stamped.resumePosition, 120)
        XCTAssertEqual(stamped.runtime, 600)
        XCTAssertEqual(stamped.playedPercentage ?? 0, 0.2, accuracy: 0.001)
        XCTAssertFalse(stamped.isPlayed)
    }

    /// Containers (series/season/folder/collection) carry no watch record, so
    /// stamping must not mutate them (and must not query the catalog).
    func testWatchStateServiceSkipsContainers() async throws {
        let reader = FakeCatalogReader()
        let service = ShareWatchStateService(
            watchStore: makeWatchStore(),
            accountID: "acct",
            catalog: { reader }
        )
        let series = MediaItem(id: "series:x", title: "Series", kind: .series)

        let stamped = await service.stamp(series)

        XCTAssertNil(stamped.resumePosition)
        XCTAssertFalse(stamped.isPlayed)
    }

    /// Continue Watching folds several legacy per-file records onto one canonical
    /// id, keeping the newest.
    func testWatchStateServiceFoldsLegacyVersionsToNewest() async throws {
        let reader = FakeCatalogReader()
        reader.canonicalMap = ["f:a.mkv": "movie:x", "f:b.mkv": "movie:x"]
        let watchStore = makeWatchStore()
        await watchStore.setResume(30, itemID: "f:a.mkv", capturedAt: Date(timeIntervalSince1970: 100), duration: 600)
        await watchStore.setResume(300, itemID: "f:b.mkv", capturedAt: Date(timeIntervalSince1970: 200), duration: 600)
        let service = ShareWatchStateService(
            watchStore: watchStore,
            accountID: "acct",
            catalog: { reader }
        )

        let folded = await service.allCanonicalRecords()

        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded["movie:x"]?.position, 300)
    }

    // MARK: Source-inspection gate

    private func providerShareSource(_ file: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // ProviderShareTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let source = repoRoot
            .appendingPathComponent("Sources/ProviderShare")
            .appendingPathComponent(file)
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// The facade must not annotate any property/return with the concrete
    /// `ShareCatalogStore`, and must depend on the read capability instead. (The one
    /// permitted mention is a doc-comment naming what it deliberately avoids.)
    func testProviderSourceNamesNoConcreteCatalogStore() throws {
        let source = try providerShareSource("ShareProvider.swift")
        XCTAssertFalse(source.contains(": ShareCatalogStore"), "facade should not annotate a ShareCatalogStore property/param")
        XCTAssertFalse(source.contains("-> ShareCatalogStore"), "facade should not return the concrete store")
        XCTAssertFalse(source.contains("catalogOverride"), "the concrete-store test override was removed")
        XCTAssertTrue(source.contains("any ShareCatalogReading"), "facade should depend on the read capability")
    }

    /// The public initializer accepts the coordinating capability, not the concrete
    /// coordinator, so AppShell/tests can inject a fake.
    func testProviderPublicInitTakesCoordinatingCapability() throws {
        let source = try providerShareSource("ShareProvider.swift")
        XCTAssertTrue(source.contains("catalogCoordinator: any ShareCatalogCoordinating"))
        XCTAssertFalse(source.contains("catalogCoordinator: ShareCatalogCoordinator,"), "public init must not require the concrete coordinator")
    }
}
