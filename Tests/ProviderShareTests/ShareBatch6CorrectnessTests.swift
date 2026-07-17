import CoreModels
import CoreNetworking
import Foundation
import MediaTransportCore
@testable import ProviderShare
import XCTest

/// Batch 6 adversarial coverage: JSON-decoded catalog ordering (B4), root-aware
/// NFO field acceptance across parser/encoder/projection (C1), strict impossible-date
/// rejection (C2), path-private aggregate scan diagnostics (C3), and the one-shot
/// parser-version reread of already-indexed sidecars.
final class ShareBatch6CorrectnessTests: XCTestCase {

    // MARK: - Fixtures / helpers

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-batch6-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func dir(_ name: String) -> RemoteFileEntry {
        try! RemoteFileEntry(relativePath: name, kind: .directory, modifiedAt: Date())
    }

    private func file(_ name: String, etag: String = "\"e1\"") -> RemoteFileEntry {
        try! RemoteFileEntry(
            relativePath: name, kind: .file, size: 100, modifiedAt: Date(), strongETag: etag
        )
    }

    private func makeScanner(
        store: ShareCatalogStore,
        tree: [String: [RemoteFileEntry]]
    ) -> ShareScanner {
        let fake = Batch6FakeShare(tree)
        return ShareScanner(store: store, concurrency: 2, makeLister: {
            ShareScanner.ScanLister(list: { await fake.list($0) }, close: {})
        })
    }

    private func makeEnricher(
        store: ShareCatalogStore,
        spy: MetadataFileSystemSpy
    ) -> ShareLocalMetadataEnricher {
        let session = MetadataTestSession(fileSystem: spy)
        return ShareLocalMetadataEnricher(store: store, sessionFactory: { _ in session })
    }

    private func drain(_ enricher: ShareLocalMetadataEnricher) async {
        var result = await enricher.resolvePendingSlice(maxItems: 50, maxDuration: .seconds(5))
        while result.hasMore {
            result = await enricher.resolvePendingSlice(maxItems: 50, maxDuration: .seconds(5))
        }
    }

    private static func nfo(_ xml: String) -> Data { Data(xml.utf8) }

    /// Local equivalent of the ShareNFOParserTests `parsed` helper (that one is private
    /// to its file): parse and unwrap the `ParsedNFO`, or nil for a non-parsed outcome.
    private func parsedDoc(_ xml: String) -> ParsedNFO? {
        guard case .parsed(let value) = ShareNFOParser.parse(Data(xml.utf8)) else { return nil }
        return value
    }

    private actor Batch6FakeShare {
        private let tree: [String: [RemoteFileEntry]]
        init(_ tree: [String: [RemoteFileEntry]]) { self.tree = tree }
        func list(_ path: String) -> [RemoteFileEntry] { tree[path] ?? [] }
    }

    // MARK: - B4: JSON-decoded ordering

    /// json1 (`json_valid`/`json_extract`) must be available on the deployment SQLite;
    /// the new ordering expression depends on it. This proves the scalar decode against
    /// the real bundled library — including escape decoding — before relying on it.
    func testJSON1FunctionsAvailableOnDeploymentSQLite() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        // Force the catalog file into existence via a real store op.
        let store = fixture.makeStore()
        _ = await store.movies(offset: 0, limit: 1)

        XCTAssertEqual(try fixture.integer("SELECT json_valid('\"x\"');"), 1)
        XCTAssertEqual(try fixture.integer("SELECT json_valid('not json');"), 0)
        XCTAssertEqual(try fixture.text("SELECT json_extract('\"a\\\"b\"', '$');"), "a\"b",
                       "json_extract must DECODE the escaped inner quote, unlike a raw substr")
        XCTAssertEqual(try fixture.text("SELECT json_extract('\"a\\nb\"', '$');"), "a\nb",
                       "control-character escapes decode to the real character")
        XCTAssertEqual(try fixture.text("SELECT json_extract('\"a\\\\b\"', '$');"), "a\\b",
                       "an escaped backslash decodes to a single backslash")
    }

    /// Movie sort titles containing quotes, backslashes, and Unicode must order by the
    /// DECODED scalar (BINARY byte order), not the escaped JSON text — a quoted phrase
    /// (`"Round"`, first byte 0x22) must sort ahead of `Alpha` (0x41), which the old
    /// `substr` expression (leaving a leading backslash 0x5C) got wrong. Verified across
    /// page boundaries with no duplicate or skip.
    func testMovieSortTitlesDecodeForOrderingAcrossPages() async throws {
        let store = ShareCatalogStore(accountKey: "b4-movie-sort", directory: tempDir())
        // (folder, display title, sort title). Expected BINARY order by decoded sort key:
        //   "Round" (0x22) < Alpha (0x41) < Zulu (0x5A) < a\b (0x61) < Ñ (0xC3).
        let specs: [(folder: String, title: String, sort: String)] = [
            ("Zulu (2001)", "ZuluMovie", "Zulu"),
            ("Round (2002)", "RoundMovie", "&quot;Round&quot;"),
            ("Uni (2003)", "UnicodeMovie", "\u{00D1}ovie"),
            ("Alpha (2004)", "AlphaMovie", "Alpha"),
            ("Back (2005)", "BackslashMovie", "a\\b"),
        ]
        var tree: [String: [RemoteFileEntry]] = ["": [dir("Movies")]]
        tree["Movies"] = specs.map { dir("Movies/\($0.folder)") }
        var files: [String: Data] = [:]
        for spec in specs {
            let base = "Movies/\(spec.folder)"
            tree[base] = [file("\(base)/movie.mkv"), file("\(base)/movie.nfo")]
            files["\(base)/movie.nfo"] = Self.nfo(
                "<movie><title>\(spec.title)</title><sorttitle>\(spec.sort)</sorttitle></movie>"
            )
        }
        await makeScanner(store: store, tree: tree).scan()
        let spy = MetadataFileSystemSpy(files: files)
        await drain(makeEnricher(store: store, spy: spy))

        let expected = ["RoundMovie", "AlphaMovie", "ZuluMovie", "BackslashMovie", "UnicodeMovie"]
        let full = await store.movies(offset: 0, limit: 10).map(\.title)
        XCTAssertEqual(full, expected, "decoded scalar ordering (BINARY bytes), not escaped JSON")

        // Same order must hold across page boundaries with no dup/skip.
        var paged: [String] = []
        for offset in stride(from: 0, to: expected.count, by: 2) {
            paged += await store.movies(offset: offset, limit: 2).map(\.title)
        }
        XCTAssertEqual(paged, expected, "pagination preserves the decoded order exactly")
    }

    /// A legacy/malformed non-JSON `sortTitle` row must not abort the paging query: the
    /// `json_valid` guard falls back to the scan-derived sort title and the item still
    /// lists.
    func testInvalidLegacyJSONSortTitleFallsBackWithoutError() async throws {
        let fixture = ShareCatalogSQLiteFixture(accountKey: "b4-bad-json")
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Movies/Solo (2018)")],
            "Movies/Solo (2018)": [file("Movies/Solo (2018)/Solo (2018).mkv")],
        ]
        await makeScanner(store: store, tree: tree).scan()

        // Seed a deliberately INVALID JSON localNFO sort-title row for the movie item.
        try fixture.execute("""
        INSERT INTO metadata_values(item_id, field, source, value_json)
        VALUES ('f:Movies/Solo (2018)/Solo (2018).mkv', 'sortTitle', 'localNFO', 'not-valid-json');
        """)

        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.count, 1, "an invalid legacy JSON sort key must not drop or abort the row")
    }

    /// The same decoded ordering applies to the series paging query (which decodes an
    /// aggregated `MIN(value_json)` scalar).
    func testSeriesSortTitlesDecodeForOrdering() async throws {
        let store = ShareCatalogStore(accountKey: "b4-series-sort", directory: tempDir())
        let specs: [(folder: String, sort: String)] = [
            ("Zeta", "Zeta"),
            ("Quoted", "&quot;Quoted&quot;"),
            ("Beta", "Beta"),
        ]
        var tree: [String: [RemoteFileEntry]] = ["": [dir("TV")]]
        tree["TV"] = specs.map { dir("TV/\($0.folder)") }
        var files: [String: Data] = [:]
        for spec in specs {
            let base = "TV/\(spec.folder)"
            tree[base] = [dir("\(base)/Season 01"), file("\(base)/tvshow.nfo")]
            let ep = "\(base)/Season 01/\(spec.folder) - S01E01.mkv"
            tree["\(base)/Season 01"] = [file(ep)]
            files["\(base)/tvshow.nfo"] = Self.nfo(
                "<tvshow><title>\(spec.folder)</title><sorttitle>\(spec.sort)</sorttitle></tvshow>"
            )
        }
        await makeScanner(store: store, tree: tree).scan()
        let spy = MetadataFileSystemSpy(files: files)
        await drain(makeEnricher(store: store, spy: spy))

        let order = await store.series(in: .tv, offset: 0, limit: 10).map(\.title)
        XCTAssertEqual(order, ["Quoted", "Beta", "Zeta"],
                       "series decoded order: \"Quoted\" (0x22) < Beta (0x42) < Zeta (0x5A)")
    }

    // MARK: - C1: episode-only fields never leak to non-episodes

    /// The PARSER must reject `season`/`episode`/`aired` unless the document root is
    /// `episodedetails` (first defense boundary).
    func testParserRejectsEpisodeFieldsOutsideEpisodeRoot() {
        let tvshow = parsedDoc(
            "<tvshow><title>Show</title><season>3</season><episode>7</episode><aired>2001-01-01</aired></tvshow>"
        )
        XCTAssertNil(tvshow?.season)
        XCTAssertNil(tvshow?.episode)
        XCTAssertNil(tvshow?.aired)

        let movie = parsedDoc(
            "<movie><title>Film</title><season>2</season><episode>4</episode><aired>1999-01-01</aired></movie>"
        )
        XCTAssertNil(movie?.season)
        XCTAssertNil(movie?.episode)
        XCTAssertNil(movie?.aired)

        let episode = parsedDoc(
            "<episodedetails><title>Ep</title><season>2</season><episode>4</episode><aired>1999-03-04</aired></episodedetails>"
        )
        XCTAssertEqual(episode?.season, 2)
        XCTAssertEqual(episode?.episode, 4)
        XCTAssertEqual(episode?.aired, "1999-03-04")
    }

    /// End-to-end: a `tvshow.nfo` carrying stray season/episode values must never
    /// project them onto the series item.
    func testTVShowNFOSeasonEpisodeNeverProjectToSeries() async throws {
        let store = ShareCatalogStore(accountKey: "c1-series", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("TV")],
            "TV": [dir("TV/Show")],
            "TV/Show": [dir("TV/Show/Season 01"), file("TV/Show/tvshow.nfo")],
            "TV/Show/Season 01": [file("TV/Show/Season 01/Show - S01E01.mkv")],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let spy = MetadataFileSystemSpy(files: [
            "TV/Show/tvshow.nfo": Self.nfo(
                "<tvshow><title>Show</title><plot>Series.</plot><season>3</season><episode>7</episode></tvshow>"
            ),
        ])
        await drain(makeEnricher(store: store, spy: spy))

        let seriesList = await store.series(in: .tv, offset: 0, limit: 10)
        let series = try XCTUnwrap(seriesList.first)
        XCTAssertEqual(series.overview, "Series.", "the valid tvshow field still applies")
        XCTAssertNil(series.seasonNumber, "a tvshow.nfo must never set a series season")
        XCTAssertNil(series.episodeNumber, "a tvshow.nfo must never set a series episode")
    }

    /// A valid `episodedetails` NFO still projects season/episode onto the episode item.
    func testEpisodeNFOProjectsSeasonAndEpisode() async throws {
        let store = ShareCatalogStore(accountKey: "c1-episode", directory: tempDir())
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("TV")],
            "TV": [dir("TV/Show")],
            "TV/Show": [dir("TV/Show/Season 02")],
            "TV/Show/Season 02": [
                file("TV/Show/Season 02/Show - S02E05.mkv"),
                file("TV/Show/Season 02/Show - S02E05.nfo"),
            ],
        ]
        await makeScanner(store: store, tree: tree).scan()
        let spy = MetadataFileSystemSpy(files: [
            "TV/Show/Season 02/Show - S02E05.nfo": Self.nfo(
                "<episodedetails><title>Ep5</title><season>2</season><episode>5</episode></episodedetails>"
            ),
        ])
        await drain(makeEnricher(store: store, spy: spy))

        let seriesList = await store.series(in: .tv, offset: 0, limit: 10)
        let series = try XCTUnwrap(seriesList.first)
        let seriesKey = try XCTUnwrap(ShareCatalogID.seriesKey(forSeriesID: series.id))
        let episodes = await store.episodes(seriesKey: seriesKey, season: 2)
        let ep = try XCTUnwrap(episodes.first)
        XCTAssertEqual(ep.seasonNumber, 2)
        XCTAssertEqual(ep.episodeNumber, 5)
    }

    /// The PROJECTION kind guard (final defense boundary): even if season/episode rows
    /// somehow reach persistence for a non-episode item, they must never overlay onto a
    /// movie/series item — but must still overlay onto an episode.
    func testProjectionKindGuardRejectsEpisodeFieldsOnNonEpisode() {
        let fields: [MetadataField: ShareCatalogReadProjection.LocalFieldRow] = [
            .seasonNumber: .init(source: .localNFO, valueJSON: "3"),
            .episodeNumber: .init(source: .localNFO, valueJSON: "7"),
        ]
        let movie = ShareCatalogReadProjection.applyLocalMetadata(
            MediaItem(id: "f:x", title: "Movie", kind: .movie), fields
        )
        XCTAssertNil(movie.seasonNumber)
        XCTAssertNil(movie.episodeNumber)

        let series = ShareCatalogReadProjection.applyLocalMetadata(
            MediaItem(id: "series:x", title: "Series", kind: .series), fields
        )
        XCTAssertNil(series.seasonNumber)
        XCTAssertNil(series.episodeNumber)

        let episode = ShareCatalogReadProjection.applyLocalMetadata(
            MediaItem(id: "e:x", title: "Ep", kind: .episode), fields
        )
        XCTAssertEqual(episode.seasonNumber, 3)
        XCTAssertEqual(episode.episodeNumber, 7)
    }

    // MARK: - C2: strict impossible-date rejection

    /// `normalizeDate` is private to the parser's delegate, so validate it through the
    /// public parse boundary using a movie's `<premiered>` (root-agnostic) field.
    private func premiered(_ date: String) -> String? {
        parsedDoc("<movie><title>M</title><premiered>\(date)</premiered></movie>")?.premiered
    }

    func testDateValidationRejectsImpossibleDates() {
        XCTAssertEqual(premiered("2024-02-29"), "2024-02-29", "2024 is a leap year")
        XCTAssertEqual(premiered("2001-09-11"), "2001-09-11")
        XCTAssertEqual(premiered("2024-1-1"), "2024-01-01", "unpadded input canonicalizes")

        for bad in [
            "2023-02-29", // not a leap year
            "2024-04-31", // April has 30 days
            "2024-00-10", // zero month
            "2024-13-01", // month out of range
            "2024-01-00", // zero day
            "2024-01-32", // day out of range
            "2024-02-30", // impossible
            "not-a-date",
            "2024-02",    // wrong shape
            "24-02-10",   // non-4-digit year
        ] {
            XCTAssertNil(premiered(bad), "\(bad) must be rejected")
        }
    }

    // MARK: - C3: path-private aggregate scan diagnostics

    /// The bounded category mapper classifies by domain/code only — never the message.
    func testListFailureCategoryMapping() {
        func category(_ error: Error) -> ShareScanListFailureCategory {
            ShareScanListFailureCategory(error)
        }
        XCTAssertEqual(category(CancellationError()), .cancelled)
        XCTAssertEqual(category(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)), .timedOut)
        XCTAssertEqual(category(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)), .connectionLost)
        XCTAssertEqual(category(NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)), .authFailed)
        XCTAssertEqual(category(NSError(domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile)), .permissionDenied)
        XCTAssertEqual(category(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)), .notFound)
        XCTAssertEqual(category(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .permissionDenied)
        XCTAssertEqual(category(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))), .notFound)
        XCTAssertEqual(category(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))), .timedOut)
        XCTAssertEqual(category(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))), .connectionLost)
        XCTAssertEqual(category(NSError(domain: "SomethingElse", code: 999)), .other)
    }

    /// A directory listing failure whose error embeds a private share path must never
    /// appear in captured logs; the aggregate `share.scan done` line reports only bounded
    /// category counts.
    func testScannerFailureDiagnosticsArePathPrivateAndAggregated() async throws {
        let store = ShareCatalogStore(accountKey: "c3-private", directory: tempDir())
        let sentinel = "PRIVATE-SENTINEL-\(UUID().uuidString)/secret-library/Movie (2020).mkv"
        let failingPath = "Movies"
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies"), dir("Shows")],
            "Shows": [file("Shows/ok.mkv")],
        ]
        let fake = Batch6FakeShare(tree)
        let scanner = ShareScanner(store: store, concurrency: 2, makeLister: {
            ShareScanner.ScanLister(list: { path in
                if path == failingPath {
                    throw NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorTimedOut,
                        userInfo: [NSLocalizedDescriptionKey: "timed out listing \(sentinel)"]
                    )
                }
                return await fake.list(path)
            }, close: {})
        })
        await scanner.scan()

        let entries = PlozzLog.recentEntries(limit: 500)
        XCTAssertFalse(
            entries.contains { $0.message.contains(sentinel) },
            "no captured log line may contain the private share path"
        )
        let done = try XCTUnwrap(
            entries.last { $0.message.contains("share.scan done") },
            "an aggregate completion line must be emitted"
        )
        XCTAssertTrue(done.message.contains("failed=1"), "accurate aggregate failure count: \(done.message)")
        XCTAssertTrue(done.message.contains("failures=[timedOut:1]"), "bounded category tally: \(done.message)")
        XCTAssertTrue(done.message.contains("pruned=false"), "a failed listing suppresses pruning")
        XCTAssertFalse(done.message.contains("Movies"), "the aggregate line carries no directory name")
    }

    // MARK: - Parser-version reread of already-indexed sidecars

    /// After a parser-rule upgrade, an already-processed sidecar whose stored
    /// `parser_version` predates the current parser is reread EXACTLY ONCE — even though
    /// its transport fingerprint is unchanged — picking up the corrected parse. The mark
    /// is idempotent (subsequent scans/slices reread nothing) and touches neither the
    /// external enrichment row nor the local materialization version.
    func testParserUpgradeRereadsUnchangedSidecarOnceAndIsIdempotent() async throws {
        let store = ShareCatalogStore(accountKey: "parser-reread", directory: tempDir())
        let itemID = "f:Movies/Dune (2021)/Dune (2021).mkv"
        let nfoPath = "Movies/Dune (2021)/Dune (2021).nfo"
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("Movies/Dune (2021)")],
            "Movies/Dune (2021)": [
                file("Movies/Dune (2021)/Dune (2021).mkv"),
                file("Movies/Dune (2021)/Dune (2021).nfo"),
            ],
        ]
        await makeScanner(store: store, tree: tree).scan()

        let spy = MetadataFileSystemSpy(files: [
            nfoPath: Self.nfo("<movie><title>Dune</title><plot>Old plot.</plot></movie>"),
        ])
        let enricher = makeEnricher(store: store, spy: spy)
        await drain(enricher)

        var movieList = await store.movies(offset: 0, limit: 1)
        var movie = try XCTUnwrap(movieList.first)
        XCTAssertEqual(movie.overview, "Old plot.")
        XCTAssertEqual(spy.readCount, 1, "one read for the initial process")

        // Seed an INDEPENDENT external enrichment row and capture the local state so we
        // can prove the reread leaves both untouched.
        let externalRecord = EnrichmentRecord(overview: "External overview.")
        _ = await store.saveEnrichment(itemID: itemID, externalRecord, version: 14)
        let localBefore = await store.localEnrichmentState(itemID: itemID)
        let externalBefore = await store.pendingEnrichmentCount(version: 14)

        // Simulate a pre-upgrade (v1) cache: restamp the processed sidecar as parser
        // version 1 without changing its association/fingerprint.
        let candidates = await store.candidateSidecars(forItemID: itemID)
        let sidecar = try XCTUnwrap(candidates.first)
        _ = await store.markSidecarProcessed(
            relPath: sidecar.relPath,
            status: "processed",
            fingerprint: sidecar.fingerprint,
            associatedItemID: sidecar.processedItemID,
            parserVersion: 1
        )

        // Change the on-disk content WITHOUT changing the transport fingerprint. Under
        // normal fingerprint-based reread this would be skipped; the parser-version reread
        // must force it.
        spy.setFile(
            Self.nfo("<movie><title>Dune</title><plot>New plot.</plot></movie>"),
            at: nfoPath
        )

        let marked = await store.markSidecarsPendingForParserUpgrade()
        XCTAssertEqual(marked, 1, "the v1 sidecar is marked pending exactly once")

        await drain(enricher)
        movieList = await store.movies(offset: 0, limit: 1)
        movie = try XCTUnwrap(movieList.first)
        XCTAssertEqual(movie.overview, "New plot.", "the forced reread applied the corrected parse")
        XCTAssertEqual(spy.readCount, 2, "exactly one additional read for the reread")

        // Idempotent: a second upgrade pass marks nothing and drives no further reads.
        let markedAgain = await store.markSidecarsPendingForParserUpgrade()
        XCTAssertEqual(markedAgain, 0, "no sidecar rereads on subsequent scans/slices")
        spy.setFile(
            Self.nfo("<movie><title>Dune</title><plot>Ignored.</plot></movie>"),
            at: nfoPath
        )
        await drain(enricher)
        movieList = await store.movies(offset: 0, limit: 1)
        movie = try XCTUnwrap(movieList.first)
        XCTAssertEqual(movie.overview, "New plot.", "an unchanged, current-version sidecar is not reread")
        XCTAssertEqual(spy.readCount, 2, "read count is stable after the one-shot upgrade")

        // External + local materialization state are untouched by the parser reread.
        let localAfter = await store.localEnrichmentState(itemID: itemID)
        XCTAssertEqual(localBefore?.version, localAfter?.version,
                       "local materialization version is unchanged by a parser reread")
        let externalAfter = await store.pendingEnrichmentCount(version: 14)
        XCTAssertEqual(externalBefore, externalAfter,
                       "the parser reread neither creates nor consumes external work")
    }
}
