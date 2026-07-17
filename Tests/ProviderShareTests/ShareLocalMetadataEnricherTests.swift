import CoreModels
import Foundation
import MediaTransportCore
@testable import ProviderShare
import XCTest

/// End-to-end coverage for the LOCAL (NFO / explicit-id) metadata pass: sidecar
/// association, bounded parsing through a fake `.metadata` transport, priority
/// against external/legacy data, and independence from the existing external
/// enrichment version/attempts.
final class ShareLocalMetadataEnricherTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-local-metadata-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func dir(_ name: String) -> RemoteFileEntry {
        try! RemoteFileEntry(relativePath: name, kind: .directory, modifiedAt: Date())
    }

    private func file(
        _ name: String,
        size: Int64 = 100,
        etag: String = "\"e1\""
    ) -> RemoteFileEntry {
        try! RemoteFileEntry(
            relativePath: name,
            kind: .file,
            size: size,
            modifiedAt: Date(),
            strongETag: etag
        )
    }

    private func makeScanner(store: ShareCatalogStore, tree: [String: [RemoteFileEntry]]) -> ShareScanner {
        let fake = LocalMetaFakeShare(tree)
        return ShareScanner(store: store, concurrency: 2, makeLister: {
            ShareScanner.ScanLister(list: { await fake.list($0) }, close: {})
        })
    }

    private func makeLocalEnricher(
        store: ShareCatalogStore,
        files: [String: Data]
    ) -> ShareLocalMetadataEnricher {
        let fileSystem = LocalMetaFakeFileSystem(files: files)
        return makeLocalEnricher(store: store, fileSystem: fileSystem)
    }

    private func makeLocalEnricher(
        store: ShareCatalogStore,
        fileSystem: LocalMetaFakeFileSystem
    ) -> ShareLocalMetadataEnricher {
        let session = LocalMetaFakeSession(fileSystem: fileSystem)
        return ShareLocalMetadataEnricher(store: store, sessionFactory: { _ in session })
    }

    private actor LocalMetaFakeShare {
        private let tree: [String: [RemoteFileEntry]]
        init(_ tree: [String: [RemoteFileEntry]]) { self.tree = tree }
        func list(_ path: String) -> [RemoteFileEntry] { tree[path] ?? [] }
    }

    private static func nfo(_ xml: String) -> Data { Data(xml.utf8) }

    // MARK: - Movie: exact-stem wins, movie.nfo fills missing

    func testExactMovieStemWinsAndGenericFillsMissingFields() async throws {
        let store = ShareCatalogStore(accountKey: "movie-nfo", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [
                file("Arrival (2016).mkv"),
                file("Arrival (2016).nfo", etag: "\"stem-e1\""),
                file("movie.nfo", etag: "\"generic-e1\""),
            ],
        ]
        await makeScanner(store: store, tree: tree).scan()

        let files: [String: Data] = [
            "Movies/Arrival (2016)/Arrival (2016).nfo": Self.nfo(
                "<movie><title>Arrival</title><plot>Exact stem plot.</plot></movie>"
            ),
            "Movies/Arrival (2016)/movie.nfo": Self.nfo(
                "<movie><title>Should Not Win</title><plot>Generic plot.</plot><genre>Drama</genre></movie>"
            ),
        ]
        let localEnricher = makeLocalEnricher(store: store, files: files)
        var result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        while result.hasMore {
            result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        }

        let movies = await store.movies(offset: 0, limit: 10)
        let item = try XCTUnwrap(movies.first)
        XCTAssertEqual(item.title, "Arrival", "exact-stem title wins over movie.nfo")
        XCTAssertEqual(item.overview, "Exact stem plot.", "exact-stem overview wins")
        XCTAssertEqual(item.genres, ["Drama"], "movie.nfo fills the genre the exact-stem left unset")
        XCTAssertEqual(item.metadataProvenance[.title]?.source, .localNFO)
        XCTAssertNil(item.metadataProvenance[.title]?.sourceURL, "local provenance never carries a sourceURL")
        XCTAssertNil(item.metadataProvenance[.genres]?.sourceURL)
    }

    func testAmbiguousGenericMovieNFODoesNotApply() async throws {
        let store = ShareCatalogStore(accountKey: "movie-ambiguous", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Double Feature")],
            "Movies/Double Feature": [
                file("First (2001).mkv"),
                file("Second (2005).mkv"),
                file("movie.nfo"),
            ],
        ]
        await makeScanner(store: store, tree: tree).scan()

        let files: [String: Data] = [
            "Movies/Double Feature/movie.nfo": Self.nfo("<movie><title>Ambiguous</title></movie>"),
        ]
        let localEnricher = makeLocalEnricher(store: store, files: files)
        var result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        while result.hasMore {
            result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        }

        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertTrue(movies.allSatisfy { $0.title != "Ambiguous" }, "an ambiguous movie.nfo must not apply")
    }

    // MARK: - Series: tvshow.nfo applies at series level, never overrides episode-local data

    func testTVShowNFOAppliesToSeriesAndEpisodeStemWinsForEpisode() async throws {
        let store = ShareCatalogStore(accountKey: "series-nfo", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("TV Shows")],
            "TV Shows": [dir("Breaking Bad")],
            "TV Shows/Breaking Bad": [dir("Season 01"), file("tvshow.nfo")],
            "TV Shows/Breaking Bad/Season 01": [
                file("Breaking Bad - S01E01 - Pilot.mkv"),
                file("Breaking Bad - S01E01 - Pilot.nfo"),
            ],
        ]
        await makeScanner(store: store, tree: tree).scan()

        let files: [String: Data] = [
            "TV Shows/Breaking Bad/tvshow.nfo": Self.nfo(
                "<tvshow><title>Breaking Bad</title><plot>Series plot.</plot></tvshow>"
            ),
            "TV Shows/Breaking Bad/Season 01/Breaking Bad - S01E01 - Pilot.nfo": Self.nfo(
                "<episodedetails><title>Pilot Title</title><plot>Episode-local plot.</plot></episodedetails>"
            ),
        ]
        let localEnricher = makeLocalEnricher(store: store, files: files)
        var result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        while result.hasMore {
            result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        }

        let series = await store.series(in: .tv, offset: 0, limit: 10)
        let show = try XCTUnwrap(series.first)
        XCTAssertEqual(show.overview, "Series plot.")

        let episodes = await store.episodes(seriesKey: try XCTUnwrap(ShareCatalogID.seriesKey(forSeriesID: show.id)), season: 1)
        let episode = try XCTUnwrap(episodes.first)
        XCTAssertEqual(episode.title, "Pilot Title")
        XCTAssertEqual(episode.overview, "Episode-local plot.", "episode-local NFO wins; tvshow.nfo never overrides it")
    }

    // MARK: - Urgent (opened-item) path outcomes

    func testResolveOneReturnsNoPendingWorkWhenNothingAssociates() async {
        let store = ShareCatalogStore(accountKey: "urgent-none", directory: tempDir())
        let localEnricher = makeLocalEnricher(store: store, files: [:])
        let outcome = await localEnricher.resolveOne(itemID: "f:Movies/Unknown.mkv")
        XCTAssertEqual(outcome, .noPendingWork)
    }

    func testResolveOneResolvesPendingMovieStemSidecar() async throws {
        let store = ShareCatalogStore(accountKey: "urgent-movie", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Dune (2021)")],
            "Movies/Dune (2021)": [file("Dune (2021).mkv"), file("Dune (2021).nfo")],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let files = ["Movies/Dune (2021)/Dune (2021).nfo": Self.nfo(
            "<movie><title>Dune</title><uniqueid type=\"imdb\">tt1160419</uniqueid></movie>"
        )]
        let localEnricher = makeLocalEnricher(store: store, files: files)

        let outcome = await localEnricher.resolveOne(itemID: "f:Movies/Dune (2021)/Dune (2021).mkv")
        XCTAssertEqual(outcome, .resolved)

        let localIDs = await store.localProviderIDs(forItemID: "f:Movies/Dune (2021)/Dune (2021).mkv")
        XCTAssertEqual(localIDs["imdb"], "tt1160419")
    }

    // MARK: - A4: cancellation fences (real SQLite store, real attempt counters)

    private func seedPendingMovieSidecar(
        accountKey: String
    ) async -> (store: ShareCatalogStore, itemID: String) {
        let store = ShareCatalogStore(accountKey: accountKey, directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Dune (2021)")],
            "Movies/Dune (2021)": [file("Dune (2021).mkv"), file("Dune (2021).nfo")],
        ]
        await makeScanner(store: store, tree: tree).scan()
        return (store, "f:Movies/Dune (2021)/Dune (2021).mkv")
    }

    /// A `CancellationError` thrown by the transport read must NOT be recorded as a
    /// transient failure: it leaves the sidecar pending with zero `local_attempts`
    /// so cancellation burns no attempt (finding A4).
    func testCancellationErrorDuringLocalReadBurnsNoAttempt() async throws {
        let (store, itemID) = await seedPendingMovieSidecar(accountKey: "a4-cancel-read")
        let fileSystem = LocalMetaFakeFileSystem(files: [:], readError: CancellationError())
        let localEnricher = makeLocalEnricher(store: store, fileSystem: fileSystem)

        let outcome = await localEnricher.resolveOne(itemID: itemID)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertGreaterThanOrEqual(fileSystem.readCount, 1, "the read was attempted before cancellation")
        let sidecars = await store.candidateSidecars(forItemID: itemID)
        let sidecar = try XCTUnwrap(sidecars.first)
        XCTAssertEqual(sidecar.attempts, 0, "cancellation must not burn a local attempt")
        XCTAssertEqual(sidecar.status, "pending", "the sidecar remains pending after cancellation")
    }

    /// A cancellation observed BEFORE the read (the enclosing task is already
    /// cancelled) skips the read entirely and burns no attempt.
    func testCancellationBeforeLocalReadSkipsReadAndBurnsNoAttempt() async throws {
        let (store, itemID) = await seedPendingMovieSidecar(accountKey: "a4-cancel-pre")
        let fileSystem = LocalMetaFakeFileSystem(files: [
            "Movies/Dune (2021)/Dune (2021).nfo": Self.nfo("<movie><title>Dune</title></movie>")
        ])
        let localEnricher = makeLocalEnricher(store: store, fileSystem: fileSystem)

        let task = Task { () -> ShareLocalMetadataOutcome in
            while !Task.isCancelled { await Task.yield() }
            return await localEnricher.resolveOne(itemID: itemID)
        }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(fileSystem.readCount, 0, "a pre-read cancellation must not touch transport")
        let sidecars = await store.candidateSidecars(forItemID: itemID)
        let sidecar = try XCTUnwrap(sidecars.first)
        XCTAssertEqual(sidecar.attempts, 0)
        XCTAssertEqual(sidecar.status, "pending")
    }

    /// Guard against over-swallowing: a genuine (non-cancellation) transport error
    /// while the task is NOT cancelled still records a transient failure and burns
    /// exactly one attempt, preserving the existing retry semantics.
    func testGenuineTransportErrorStillBurnsTransientAttempt() async throws {
        let (store, itemID) = await seedPendingMovieSidecar(accountKey: "a4-transient")
        let fileSystem = LocalMetaFakeFileSystem(
            files: [:],
            readError: MediaTransportError.protocolViolation(reason: "boom")
        )
        let localEnricher = makeLocalEnricher(store: store, fileSystem: fileSystem)

        let outcome = await localEnricher.resolveOne(itemID: itemID)

        XCTAssertEqual(outcome, .transientFailure)
        let sidecars = await store.candidateSidecars(forItemID: itemID)
        let sidecar = try XCTUnwrap(sidecars.first)
        XCTAssertEqual(sidecar.attempts, 1, "a real transport failure still burns one attempt")
        XCTAssertEqual(sidecar.status, "pending")
    }

    // MARK: - Local vs external write isolation (correction #1)

    func testExternalSaveNeverClobbersLocalWinner() async throws {
        let store = ShareCatalogStore(accountKey: "isolation", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [file("Arrival (2016).mkv"), file("Arrival (2016).nfo")],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let files = ["Movies/Arrival (2016)/Arrival (2016).nfo": Self.nfo(
            "<movie><title>Arrival</title><plot>Local plot wins.</plot></movie>"
        )]
        let localEnricher = makeLocalEnricher(store: store, files: files)
        var result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        while result.hasMore {
            result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        }

        // A later EXTERNAL save for the same representative file must not erase
        // the local overview, and must still persist its own artwork/ids.
        var record = ShareCatalogStore.EnrichmentRecord()
        record.overview = "External overview should not win."
        record.posterURL = URL(string: "https://example.com/poster.jpg")
        let saved = await store.saveEnrichment(itemID: "f:Movies/Arrival (2016)/Arrival (2016).mkv", record, version: 1)
        XCTAssertTrue(saved)

        let movies = await store.movies(offset: 0, limit: 10)
        let item = try XCTUnwrap(movies.first)
        XCTAssertEqual(item.overview, "Local plot wins.", "external save must never clobber a local winner")
        XCTAssertEqual(item.posterURL, URL(string: "https://example.com/poster.jpg"), "external artwork still fills in")
    }

    func testLocalProviderIDReplacesCaseEquivalentExternalID() async throws {
        let store = ShareCatalogStore(accountKey: "id-priority", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [file("Arrival (2016).mkv"), file("Arrival (2016).nfo")],
        ]
        await makeScanner(store: store, tree: tree).scan()
        _ = await makeLocalEnricher(store: store, files: [
            "Movies/Arrival (2016)/Arrival (2016).nfo":
                Self.nfo("<movie><uniqueid type=\"tmdb\">100</uniqueid></movie>"),
        ]).resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        await store.saveEnrichment(
            itemID: "f:Movies/Arrival (2016)/Arrival (2016).mkv",
            .init(providerIDs: ["Tmdb": "200"]),
            version: ShareEnricher.version
        )

        let movies = await store.movies(offset: 0, limit: 1)
        let item = try XCTUnwrap(movies.first)
        XCTAssertEqual(item.providerIDs["Tmdb"], "100")
        XCTAssertNil(item.providerIDs["tmdb"])
        XCTAssertEqual(
            item.providerIDs.keys.filter {
                ShareMediaParser.canonicalProviderNamespace($0) == "tmdb"
            }.count,
            1
        )
    }

    // MARK: - Zero external resolver calls when local fully satisfies + external disabled/no-op

    func testProviderDisabledFixtureProjectsLocalFieldsWithZeroResolverCalls() async throws {
        let store = ShareCatalogStore(accountKey: "offline", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [file("Arrival (2016).mkv"), file("Arrival (2016).nfo")],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let files = ["Movies/Arrival (2016)/Arrival (2016).nfo": Self.nfo(
            "<movie><title>Arrival</title><plot>Fully local.</plot><uniqueid type=\"imdb\">tt2543164</uniqueid></movie>"
        )]
        let localEnricher = makeLocalEnricher(store: store, files: files)
        var result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        while result.hasMore {
            result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        }

        // No `ShareEnricher`/resolver is ever constructed or invoked in this
        // test — the local pass alone fully projects title/overview/ids, and
        // provenance carries no sourceURL/host/credential material.
        let movies = await store.movies(offset: 0, limit: 10)
        let item = try XCTUnwrap(movies.first)
        XCTAssertEqual(item.title, "Arrival")
        XCTAssertEqual(item.overview, "Fully local.")
        XCTAssertEqual(item.providerID(.imdb), "tt2543164")
        XCTAssertNil(item.metadataProvenance[.overview]?.sourceURL)
    }

    // MARK: - Fingerprints, invalidation, and transport bounds

    func testUnchangedFingerprintIsNotRereadAcrossSlicesOrCleanScans() async throws {
        let store = ShareCatalogStore(accountKey: "unchanged", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [
                file("Arrival (2016).mkv"),
                file("Arrival (2016).nfo", etag: "\"stable\""),
            ],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let path = "Movies/Arrival (2016)/Arrival (2016).nfo"
        let fileSystem = LocalMetaFakeFileSystem(files: [
            path: Self.nfo("<movie><plot>Read once.</plot></movie>"),
        ])
        let localEnricher = makeLocalEnricher(store: store, fileSystem: fileSystem)
        _ = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        XCTAssertEqual(fileSystem.readCount, 1)

        _ = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        await makeScanner(store: store, tree: tree).scan()
        _ = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        XCTAssertEqual(fileSystem.readCount, 1, "an unchanged terminal fingerprint must not be reread")
    }

    func testWeakFingerprintReadsAtMostOncePerSuccessfulScan() async throws {
        let store = ShareCatalogStore(accountKey: "weak-fingerprint", directory: tempDir())
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let weakNFO = try RemoteFileEntry(
            relativePath: "Arrival (2016).nfo",
            kind: .file,
            size: 100,
            modifiedAt: modifiedAt
        )
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [file("Arrival (2016).mkv"), weakNFO],
        ]
        let path = "Movies/Arrival (2016)/Arrival (2016).nfo"
        let fileSystem = LocalMetaFakeFileSystem(files: [
            path: Self.nfo("<movie><plot>Weak transport.</plot></movie>"),
        ])
        let localEnricher = makeLocalEnricher(store: store, fileSystem: fileSystem)
        await makeScanner(store: store, tree: tree).scan()
        _ = await localEnricher.resolveOne(
            itemID: "f:Movies/Arrival (2016)/Arrival (2016).mkv"
        )
        _ = await localEnricher.resolveOne(
            itemID: "f:Movies/Arrival (2016)/Arrival (2016).mkv"
        )
        XCTAssertEqual(fileSystem.readCount, 1)

        await makeScanner(store: store, tree: tree).scan()
        _ = await localEnricher.resolveOne(
            itemID: "f:Movies/Arrival (2016)/Arrival (2016).mkv"
        )
        XCTAssertEqual(fileSystem.readCount, 2)
    }

    func testChangedMalformedAndEmptySidecarsRemoveStaleValues() async throws {
        let store = ShareCatalogStore(accountKey: "changed-invalid", directory: tempDir())
        func tree(etag: String) -> [String: [RemoteFileEntry]] {
            [
                "": [dir("Movies")],
                "Movies": [dir("Arrival (2016)")],
                "Movies/Arrival (2016)": [
                    file("Arrival (2016).mkv"),
                    file("Arrival (2016).nfo", etag: etag),
                ],
            ]
        }
        let path = "Movies/Arrival (2016)/Arrival (2016).nfo"
        await makeScanner(store: store, tree: tree(etag: "\"v1\"")).scan()
        _ = await makeLocalEnricher(store: store, files: [
            path: Self.nfo("<movie><plot>Stale plot.</plot></movie>"),
        ]).resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        var movies = await store.movies(offset: 0, limit: 1)
        XCTAssertEqual(movies.first?.overview, "Stale plot.")

        await makeScanner(store: store, tree: tree(etag: "\"v2\"")).scan()
        movies = await store.movies(offset: 0, limit: 1)
        XCTAssertNil(movies.first?.overview, "changed fingerprints must stop projecting stale values immediately")
        _ = await makeLocalEnricher(store: store, files: [
            path: Self.nfo("<movie><plot>broken</movie>"),
        ]).resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        movies = await store.movies(offset: 0, limit: 1)
        XCTAssertNil(movies.first?.overview)

        await makeScanner(store: store, tree: tree(etag: "\"v3\"")).scan()
        _ = await makeLocalEnricher(store: store, files: [
            path: Self.nfo("<movie><plot>Fresh plot.</plot></movie>"),
        ]).resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        movies = await store.movies(offset: 0, limit: 1)
        XCTAssertEqual(movies.first?.overview, "Fresh plot.")

        await makeScanner(store: store, tree: tree(etag: "\"v4\"")).scan()
        _ = await makeLocalEnricher(store: store, files: [
            path: Self.nfo("<movie></movie>"),
        ]).resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        movies = await store.movies(offset: 0, limit: 1)
        XCTAssertNil(movies.first?.overview)
    }

    func testDeletingExactSidecarReusesUnchangedGenericCacheAsFallback() async throws {
        let store = ShareCatalogStore(accountKey: "deleted-exact", directory: tempDir())
        let fullTree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [
                file("Arrival (2016).mkv"),
                file("Arrival (2016).nfo", etag: "\"exact\""),
                file("movie.nfo", etag: "\"generic\""),
            ],
        ]
        await makeScanner(store: store, tree: fullTree).scan()
        let fileSystem = LocalMetaFakeFileSystem(files: [
            "Movies/Arrival (2016)/Arrival (2016).nfo":
                Self.nfo("<movie><plot>Exact plot.</plot></movie>"),
            "Movies/Arrival (2016)/movie.nfo":
                Self.nfo("<movie><plot>Generic fallback.</plot></movie>"),
        ])
        let localEnricher = makeLocalEnricher(store: store, fileSystem: fileSystem)
        var result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        while result.hasMore {
            result = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        }
        var movies = await store.movies(offset: 0, limit: 1)
        XCTAssertEqual(movies.first?.overview, "Exact plot.")
        XCTAssertEqual(fileSystem.readCount, 2)

        var deletedTree = fullTree
        deletedTree["Movies/Arrival (2016)"] = [
            file("Arrival (2016).mkv"),
            file("movie.nfo", etag: "\"generic\""),
        ]
        await makeScanner(store: store, tree: deletedTree).scan()
        movies = await store.movies(offset: 0, limit: 1)
        XCTAssertEqual(movies.first?.overview, "Generic fallback.")
        _ = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        XCTAssertEqual(fileSystem.readCount, 2, "unchanged generic cache must be reused")
    }

    func testGenericSidecarStopsApplyingWhenDirectoryBecomesAmbiguousAndRecoversFromCache() async throws {
        let store = ShareCatalogStore(accountKey: "generic-reassociate", directory: tempDir())
        let singleMovie: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Feature")],
            "Movies/Feature": [
                file("First (2001).mkv"),
                file("movie.nfo", etag: "\"generic\""),
            ],
        ]
        await makeScanner(store: store, tree: singleMovie).scan()
        let fileSystem = LocalMetaFakeFileSystem(files: [
            "Movies/Feature/movie.nfo": Self.nfo("<movie><plot>Generic metadata.</plot></movie>"),
        ])
        let localEnricher = makeLocalEnricher(store: store, fileSystem: fileSystem)
        _ = await localEnricher.resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        var movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.first?.overview, "Generic metadata.")
        XCTAssertEqual(fileSystem.readCount, 1)

        var ambiguous = singleMovie
        ambiguous["Movies/Feature"] = [
            file("First (2001).mkv"),
            file("Second (2005).mkv"),
            file("movie.nfo", etag: "\"generic\""),
        ]
        await makeScanner(store: store, tree: ambiguous).scan()
        movies = await store.movies(offset: 0, limit: 10)
        XCTAssertTrue(movies.allSatisfy { $0.overview == nil })

        await makeScanner(store: store, tree: singleMovie).scan()
        movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.first?.overview, "Generic metadata.")
        XCTAssertEqual(fileSystem.readCount, 1, "reassociation must reuse the parsed cache")
    }

    func testCleanScanRemovesOrphanedFilenameProviderIDs() async throws {
        let store = ShareCatalogStore(accountKey: "filename-prune", directory: tempDir())
        let taggedPath = "Movies/Arrival (2016) [imdb-tt2543164].mkv"
        let taggedTree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [file("Arrival (2016) [imdb-tt2543164].mkv")],
        ]
        await makeScanner(store: store, tree: taggedTree).scan()
        let oldItemID = ShareCatalogID.file(taggedPath)
        let taggedIDs = await store.localProviderIDs(forItemID: oldItemID)
        XCTAssertEqual(taggedIDs["imdb"], "tt2543164")

        let renamedTree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [file("Arrival (2016).mkv")],
        ]
        await makeScanner(store: store, tree: renamedTree).scan()
        let orphanedIDs = await store.localProviderIDs(forItemID: oldItemID)
        XCTAssertTrue(orphanedIDs.isEmpty)
        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertNil(movies.first?.providerIDs["imdb"])
    }

    func testConflictingFilenameIDsForOneMovieGroupAreOmitted() async throws {
        let store = ShareCatalogStore(accountKey: "filename-conflict", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [
                file("Arrival (2016) [tmdb-100].mkv"),
                file("Arrival (2016) [tmdb-200] 4K.mkv"),
            ],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.count, 1)
        XCTAssertNil(movies.first?.providerIDs["tmdb"])
    }

    func testOutdatedLocalVersionRematerializesCacheWithoutTransportRead() async throws {
        let store = ShareCatalogStore(accountKey: "local-version", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [file("Arrival (2016).mkv"), file("Arrival (2016).nfo")],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let itemID = "f:Movies/Arrival (2016)/Arrival (2016).mkv"
        _ = await makeLocalEnricher(store: store, files: [
            "Movies/Arrival (2016)/Arrival (2016).nfo":
                Self.nfo("<movie><plot>Cached plot.</plot></movie>"),
        ]).resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        await store.writeLocalEnrichmentState(itemID: itemID, version: 0, attempts: 0)

        let fileSystem = LocalMetaFakeFileSystem(files: [:])
        let result = await makeLocalEnricher(
            store: store,
            fileSystem: fileSystem
        ).resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))
        XCTAssertEqual(result.attempted, 1)
        XCTAssertEqual(fileSystem.readCount, 0)
        let movies = await store.movies(offset: 0, limit: 1)
        XCTAssertEqual(movies.first?.overview, "Cached plot.")
    }

    func testKnownOversizedSidecarIsRejectedBeforeTransportRead() async throws {
        let store = ShareCatalogStore(accountKey: "oversized", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [
                file("Arrival (2016).mkv"),
                file("Arrival (2016).nfo", size: Int64(ShareNFOParser.maxBytes + 1)),
            ],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let fileSystem = LocalMetaFakeFileSystem(files: [:])
        let outcome = await makeLocalEnricher(store: store, fileSystem: fileSystem).resolveOne(
            itemID: "f:Movies/Arrival (2016)/Arrival (2016).mkv"
        )
        XCTAssertEqual(outcome, .terminal)
        XCTAssertEqual(fileSystem.readCount, 0)
    }

    func testOpenedItemSeedsExternalRequestOnlyAfterLocalIDPersists() async throws {
        let store = ShareCatalogStore(accountKey: "urgent-order", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Dune (2021)")],
            "Movies/Dune (2021)": [file("Dune (2021).mkv"), file("Dune (2021).nfo")],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let itemID = "f:Movies/Dune (2021)/Dune (2021).mkv"
        let local = makeLocalEnricher(store: store, files: [
            "Movies/Dune (2021)/Dune (2021).nfo":
                Self.nfo("<movie><uniqueid type=\"tvdb\">348031</uniqueid></movie>"),
        ])
        let recorder = LocalMetaResolverRecorder(record: .init(
            posterURL: URL(string: "https://example.com/dune.jpg")
        ))

        let localOutcome = await local.resolveOne(itemID: itemID)
        XCTAssertEqual(localOutcome, .resolved)
        await ShareEnricher(store: store, resolver: recorder).enrichOne(itemID: itemID)

        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.knownProviderIDs["tvdb"], "348031")
        let storedItem = await store.item(id: itemID)
        let item = try XCTUnwrap(storedItem)
        XCTAssertEqual(item.posterURL, URL(string: "https://example.com/dune.jpg"))
    }

    func testEncodedMediaItemDoesNotExposeLocalPathOrTransportIdentity() async throws {
        let store = ShareCatalogStore(accountKey: "privacy", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Arrival (2016)")],
            "Movies/Arrival (2016)": [file("Arrival (2016).mkv"), file("Arrival (2016).nfo")],
        ]
        await makeScanner(store: store, tree: tree).scan()
        _ = await makeLocalEnricher(store: store, files: [
            "Movies/Arrival (2016)/Arrival (2016).nfo":
                Self.nfo("<movie><plot>Private local metadata.</plot></movie>"),
        ]).resolvePendingSlice(maxItems: 10, maxDuration: .seconds(5))

        let movies = await store.movies(offset: 0, limit: 1)
        let item = try XCTUnwrap(movies.first)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(item), encoding: .utf8))
        XCTAssertFalse(encoded.contains("Arrival (2016).nfo"))
        XCTAssertFalse(encoded.contains("nas.local"))
        XCTAssertFalse(encoded.contains("/Media"))
        XCTAssertNil(item.metadataProvenance[.overview]?.sourceURL)
    }
}

private final class LocalMetaFakeSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    init(fileSystem: any MediaTransportFileSystem) {
        self.key = try! MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: CredentialRevision(),
            endpoint: try! MediaTransportEndpointIdentity(
                transportIdentifier: "smb",
                host: "nas.local",
                rootPath: "/Media"
            ),
            trustRevision: UUID(),
            role: .metadata
        )
        self.fileSystem = fileSystem
    }

    func shutdown() async {}
}

private final class LocalMetaFakeFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    private let files: [String: Data]
    private let readError: (any Error)?
    private let lock = NSLock()
    private var reads = 0
    init(files: [String: Data], readError: (any Error)? = nil) {
        self.files = files
        self.readError = readError
    }

    var readCount: Int { lock.withLock { reads } }

    func validate() async throws {}

    func probe() async throws -> MediaTransportProbe {
        MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .randomAccess,
                maximumBoundedWholeFileReadBytes: ShareNFOParser.maxBytes,
                consistency: .changeDetecting
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] { [] }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        try RemoteFileEntry(relativePath: relativePath, kind: .file, size: 0)
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        lock.withLock { reads += 1 }
        if let readError { throw readError }
        guard let data = files[relativePath] else {
            throw MediaTransportError.protocolViolation(reason: "no fake data for \(relativePath)")
        }
        return data
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        throw MediaTransportError.unsupportedCapability("not used in local metadata tests")
    }
}

private actor LocalMetaResolverRecorder: ShareMetadataResolving {
    private(set) var requests: [ShareEnrichRequest] = []
    private let record: ShareCatalogStore.EnrichmentRecord

    init(record: ShareCatalogStore.EnrichmentRecord) {
        self.record = record
    }

    func resolve(_ request: ShareEnrichRequest) async -> ShareCatalogStore.EnrichmentRecord {
        requests.append(request)
        return record
    }
}
