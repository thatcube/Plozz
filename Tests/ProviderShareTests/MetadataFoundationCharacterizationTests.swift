import CoreModels
import Foundation
import MediaTransportCore
import MetadataKit
@testable import ProviderShare
import XCTest

final class MetadataFoundationCharacterizationTests: XCTestCase {
    func testFreshCatalogUsesSchemaVersionThreeAcrossReopen() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }

        let first = fixture.makeStore()
        _ = await first.libraryCounts()
        XCTAssertEqual(try fixture.integer("PRAGMA user_version;"), 3)
        XCTAssertEqual(
            try fixture.integer(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='metadata_values';"
            ),
            1
        )
        XCTAssertEqual(
            try fixture.integer(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='local_metadata_files';"
            ),
            1
        )

        let reopened = fixture.makeStore()
        _ = await reopened.libraryCounts()
        XCTAssertEqual(try fixture.integer("PRAGMA user_version;"), 3)
    }

    func testNoNFOProjectionPreservesScannerFieldsWithoutSourcedMetadata() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let generation = UUID()
        await store.activateScanGeneration(generation)
        let nextScanID = await store.nextScanID(for: generation)
        let scanID = try XCTUnwrap(nextScanID)
        await store.upsert(
            [
                CatalogAsset(
                    relPath: "Movies/Primer (2004).mkv",
                    basename: "Primer (2004).mkv",
                    size: 1_024,
                    modifiedAt: Date(timeIntervalSince1970: 100),
                    kind: .movie,
                    library: .movies,
                    title: "Primer",
                    year: 2004,
                    seriesTitle: nil,
                    seriesKey: nil,
                    season: nil,
                    episode: nil
                )
            ],
            scanID: scanID
        )

        let movies = await store.movies(offset: 0, limit: 1)
        let movie = try XCTUnwrap(movies.first)
        XCTAssertEqual(movie.title, "Primer")
        XCTAssertEqual(movie.productionYear, 2004)
        XCTAssertNil(movie.overview)
        XCTAssertTrue(movie.providerIDs.isEmpty)
        XCTAssertTrue(movie.metadataProvenance.isEmpty)
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values;"),
            0
        )
    }

    func testLocalAndExternalVersionsRemainIndependentInSQLite() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let generation = UUID()
        await store.activateScanGeneration(generation)
        let nextScanID = await store.nextScanID(for: generation)
        let scanID = try XCTUnwrap(nextScanID)
        let videoPath = "Movies/Arrival (2016)/Arrival (2016).mkv"
        let nfoPath = "Movies/Arrival (2016)/Arrival (2016).nfo"
        await store.upsert(
            [
                CatalogAsset(
                    relPath: videoPath,
                    basename: "Arrival (2016).mkv",
                    size: 1_024,
                    modifiedAt: Date(timeIntervalSince1970: 100),
                    kind: .movie,
                    library: .movies,
                    title: "Arrival",
                    year: 2016,
                    seriesTitle: nil,
                    seriesKey: nil,
                    season: nil,
                    episode: nil
                )
            ],
            scanID: scanID
        )
        await store.upsertSidecars(
            [
                LocalSidecarCandidate(
                    relPath: nfoPath,
                    parentDir: "Movies/Arrival (2016)",
                    basename: "Arrival (2016).nfo",
                    kind: .movieStem,
                    size: 100,
                    modifiedAt: Date(timeIntervalSince1970: 100),
                    stableFileID: nil,
                    strongETag: "\"nfo-v1\"",
                    changeToken: nil,
                    associatedVideoRelPath: videoPath
                )
            ],
            scanID: scanID
        )
        await store.rebuildMovieGroups()
        await store.reconcileSidecarAssociations()
        let fileSystem = MetadataFileSystemSpy(
            files: [nfoPath: Data("<movie><plot>Local overview.</plot></movie>".utf8)]
        )
        let local = ShareLocalMetadataEnricher(
            store: store,
            sessionFactory: { role in
                MetadataTestSession(fileSystem: fileSystem, role: role)
            }
        )
        let initialExternalVersion = ShareEnricher.version - 1
        let initialExternalSaved = await store.saveEnrichment(
            itemID: ShareCatalogID.file(videoPath),
            .init(posterURL: URL(string: "https://example.com/poster.jpg")),
            version: initialExternalVersion
        )
        XCTAssertTrue(initialExternalSaved)
        let localOutcome = await local.resolveOne(itemID: ShareCatalogID.file(videoPath))
        XCTAssertEqual(localOutcome, .resolved)
        XCTAssertEqual(
            try fixture.integer(
                "SELECT external_version FROM metadata_enrichment_state WHERE item_id='f:Movies/Arrival (2016)/Arrival (2016).mkv';"
            ),
            initialExternalVersion,
            "local materialization must preserve external version state"
        )
        let externalSaved = await store.saveEnrichment(
            itemID: ShareCatalogID.file(videoPath),
            .init(posterURL: URL(string: "https://example.com/poster.jpg")),
            version: ShareEnricher.version
        )
        XCTAssertTrue(externalSaved)

        XCTAssertEqual(
            try fixture.integer(
                "SELECT local_version FROM metadata_enrichment_state WHERE item_id='f:Movies/Arrival (2016)/Arrival (2016).mkv';"
            ),
            ShareLocalMetadataEnricher.version,
            "external enrichment must preserve local version state"
        )
        XCTAssertEqual(
            try fixture.integer(
                "SELECT external_version FROM metadata_enrichment_state WHERE item_id='f:Movies/Arrival (2016)/Arrival (2016).mkv';"
            ),
            ShareEnricher.version
        )
        let movies = await store.movies(offset: 0, limit: 1)
        let movie = try XCTUnwrap(movies.first)
        XCTAssertEqual(movie.overview, "Local overview.")
        XCTAssertEqual(movie.posterURL, URL(string: "https://example.com/poster.jpg"))
    }

    func testDefaultExternalResolverSelectionPreservesConfiguredFallbackOrder() {
        let clients = ShareExternalMetadataClients(
            ids: FakeShareExternalIDs(),
            artwork: FakeShareArtwork(),
            overview: FakeShareOverview(),
            tvdbConfig: { TVDBConfig(apiKey: nil) },
            makeTVDBClient: { _ in FakeTVDBMetadata() }
        )
        let keylessFactory = DefaultShareMetadataPipelineFactory(clients: clients)
        XCTAssertTrue(keylessFactory.makeExternalResolver() is KeylessShareResolver)

        let configuredClients = ShareExternalMetadataClients(
            ids: FakeShareExternalIDs(),
            artwork: FakeShareArtwork(),
            overview: FakeShareOverview(),
            tvdbConfig: { TVDBConfig(apiKey: "fixture-key") },
            makeTVDBClient: { _ in FakeTVDBMetadata() }
        )
        let configuredFactory = DefaultShareMetadataPipelineFactory(clients: configuredClients)
        XCTAssertTrue(configuredFactory.makeExternalResolver() is TVDBShareResolver)
    }

    func testCoordinatorUsesOnePipelinePerAccountGeneration() async {
        let resolver = MetadataResolverSpy()
        let factory = PipelineFactorySpy(resolver: resolver)
        let revision = CredentialRevision()
        let coordinator = ShareCatalogCoordinator(
            pipelineFactory: factory
        )
        let sessionFactory: ShareTransportSessionFactory = { role in
            MetadataTestSession(credentialRevision: revision, role: role)
        }

        _ = await coordinator.store(
            accountKey: "resolver-identity",
            displayName: "Resolver Identity",
            credentialRevision: revision,
            sessionFactory: sessionFactory
        )
        _ = await coordinator.store(
            accountKey: "resolver-identity",
            displayName: "Resolver Identity",
            credentialRevision: revision,
            sessionFactory: sessionFactory
        )

        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(Set(factory.identities).count, 1)
        await coordinator.invalidate(accountKey: "resolver-identity")
    }
}
