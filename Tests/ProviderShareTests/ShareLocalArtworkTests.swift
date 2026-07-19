import XCTest
import CoreModels
import MediaTransportCore
import MetadataKit
@testable import ProviderShare

final class ShareLocalArtworkTests: XCTestCase {
    private actor CacheLifecycleSpy: ShareLocalArtworkCacheLifecycle {
        struct Preference: Equatable {
            let accountKeys: Set<String>
            let revision: UInt64
        }

        private var preferences: [Preference] = []

        func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) {
            preferences.append(.init(accountKeys: accountKeys, revision: revision))
        }

        func purge(accountID: String) {}
        func purge(accountID: String, credentialRevision: CredentialRevision) {}
        func recordedPreferences() -> [Preference] { preferences }
    }

    private final class PrefixSource: MediaTransportByteSource, @unchecked Sendable {
        let data: Data
        let shouldFail: Bool
        private let lock = NSLock()
        private var shutdowns = 0

        init(_ data: Data, shouldFail: Bool = false) {
            self.data = data
            self.shouldFail = shouldFail
        }
        var byteSize: Int64 { Int64(data.count) }
        var shutdownCount: Int { lock.withLock { shutdowns } }
        func read(at offset: Int64, length: Int) async throws -> Data {
            if shouldFail {
                throw NSError(domain: "ShareLocalArtworkTests", code: 1)
            }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + length))
        }
        func shutdown() async { lock.withLock { shutdowns += 1 } }
    }

    private final class PrefixFileSystem: MediaTransportFileSystem, @unchecked Sendable {
        let source: PrefixSource
        private let lock = NSLock()
        private var opens = 0

        init(_ source: PrefixSource) { self.source = source }
        var openCount: Int { lock.withLock { opens } }
        func validate() async throws {}
        func probe() async throws -> MediaTransportProbe {
            try .init(capabilities: .init(
                supportsList: true, supportsStat: true, supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .randomAccess, maximumBoundedWholeFileReadBytes: 1,
                consistency: .changeDetecting
            ))
        }
        func list(relativePath: String) async throws -> [RemoteFileEntry] { [] }
        func stat(relativePath: String) async throws -> RemoteFileEntry {
            try .init(relativePath: relativePath, kind: .file, size: source.byteSize)
        }
        func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
            XCTFail("Artwork probing must not use readSmallFile")
            return Data()
        }
        func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
            lock.withLock { opens += 1 }
            return .init(source: source)
        }
    }

    private func locator(size: Int64 = 300 * 1_024) throws -> NetworkFileLocator {
        let identity = try RemoteFileIdentity(kind: .modificationTime, modifiedAt: Date())
        let representation = try RemoteFileRepresentation(size: size, identity: identity, consistency: .changeDetecting)
        return try NetworkFileLocator(
            accountID: "art-account", sourceID: "art-account", credentialRevision: CredentialRevision(),
            relativePath: "Movies/Film/poster.jpg", representation: representation
        )
    }

    func testBoundedSourcePrefixUsesOpenSourceAndWaitsForCleanup() async throws {
        let source = PrefixSource(Data(repeating: 7, count: 300 * 1_024))
        let fileSystem = PrefixFileSystem(source)
        let session = MetadataTestSession(fileSystem: fileSystem)
        let browser = ShareTransportBrowser(role: .metadata, sessionFactory: { _ in session })
        let data = try await browser.readSourcePrefix(try locator(), maximumBytes: 256 * 1_024)
        XCTAssertEqual(data.count, 256 * 1_024)
        XCTAssertEqual(fileSystem.openCount, 1)
        XCTAssertEqual(source.shutdownCount, 1)
    }

    func testTransientProbeFailureKeepsSchedulerBacklogQueued() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let revision = CredentialRevision()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: revision
        )
        await store.upsert([movie()], scanID: 1)
        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)

        let source = PrefixSource(Data(repeating: 7, count: 100), shouldFail: true)
        let session = MetadataTestSession(fileSystem: PrefixFileSystem(source))
        let browser = ShareTransportBrowser(role: .metadata, sessionFactory: { _ in session })
        let worker = ShareLocalArtworkProbeWorker(
            store: store,
            browser: browser,
            accountID: "art-account",
            credentialRevision: revision
        )

        let result = await worker.resolvePendingSlice(
            maxItems: 10,
            maxDuration: .seconds(1)
        )

        XCTAssertEqual(result.attempted, 1)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.retryAfter, .seconds(5))
        XCTAssertEqual(
            try fixture.text("SELECT probe_status FROM local_artwork_files;"),
            "pending"
        )
        XCTAssertEqual(try fixture.integer("SELECT probe_attempts FROM local_artwork_files;"), 1)
        await worker.close()
    }

    private func fixture(_ base64: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: base64))
    }

    func testIncrementalHeaderInspectionUsesActualImageIOType() throws {
        let jpeg = try fixture("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD50ooor8MP9Uz/2Q==")
        let png = try fixture("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/9neRmAAAAABJRU5ErkJggg==")
        XCTAssertEqual(ShareArtworkHeaderInspector.inspect(jpeg, sourceIsComplete: true), .validated(width: 1, height: 1, contentType: "image/jpeg"))
        XCTAssertEqual(ShareArtworkHeaderInspector.inspect(png, sourceIsComplete: true), .validated(width: 1, height: 1, contentType: "image/png"))

        let webP = try fixture("UklGRiIAAABXRUJQVlA4IBYAAADQAQCdASoBAAEAAUAmJaQAA3AA/vuUAAA=")
        let result = ShareArtworkHeaderInspector.inspect(webP, sourceIsComplete: true)
        if case .unsupported = result {
            throw XCTSkip("ImageIO WebP support is unavailable on this simulator runtime")
        }
        XCTAssertEqual(result, .validated(width: 1, height: 1, contentType: "image/webp"))
    }

    func testHeaderInspectionClassifiesTerminalAndIncompleteInputs() {
        XCTAssertEqual(ShareArtworkHeaderInspector.inspect(Data(), sourceIsComplete: true), .empty)
        XCTAssertEqual(
            ShareArtworkHeaderInspector.inspect(
                try! fixture("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="),
                sourceIsComplete: true
            ),
            .unsupported
        )
        XCTAssertEqual(ShareArtworkHeaderInspector.inspect(Data([0, 1, 2]), sourceIsComplete: true), .malformed)
        XCTAssertEqual(
            ShareArtworkHeaderInspector.inspect(Data([0x89, 0x50, 0x4E, 0x47]), sourceIsComplete: false),
            .incomplete
        )
    }

    func testTBNIsOnlyNameSyntaxAndStillRequiresValidContent() throws {
        XCTAssertNotNil(ShareArtworkNameParser.parse("poster.tbn"))
        let png = try fixture("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/9neRmAAAAABJRU5ErkJggg==")
        XCTAssertEqual(
            ShareArtworkHeaderInspector.inspect(png, sourceIsComplete: true),
            .validated(width: 1, height: 1, contentType: "image/png")
        )
    }

    func testPixelBombAndEdgeLimitAreRejectedWithoutDecode() {
        func pngHeader(width: UInt32, height: UInt32) -> Data {
            var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            data.append(contentsOf: [0, 0, 0, 13])
            data.append(contentsOf: Array("IHDR".utf8))
            for value in [width, height] {
                data.append(UInt8((value >> 24) & 0xFF))
                data.append(UInt8((value >> 16) & 0xFF))
                data.append(UInt8((value >> 8) & 0xFF))
                data.append(UInt8(value & 0xFF))
            }
            data.append(contentsOf: [8, 2, 0, 0, 0, 0, 0, 0, 0, 0])
            return data
        }
        XCTAssertEqual(
            ShareArtworkHeaderInspector.inspect(pngHeader(width: 16_385, height: 1), sourceIsComplete: false),
            .tooLarge
        )
        XCTAssertEqual(
            ShareArtworkHeaderInspector.inspect(pngHeader(width: 8_001, height: 8_001), sourceIsComplete: false),
            .tooLarge
        )
    }

    private func candidate(
        _ path: String,
        etag: String? = "\"art-1\""
    ) -> LocalArtworkCandidate {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return .init(
            relPath: path, parentDir: parent, basename: name,
            facts: ShareArtworkNameParser.parse(name)!,
            size: 100, modifiedAt: Date(timeIntervalSince1970: 100),
            stableFileID: nil, strongETag: etag, changeToken: nil,
            isBackdropFolder: false
        )
    }

    private func movie(_ path: String = "Movies/Film/Film.mkv") -> CatalogAsset {
        .init(
            relPath: path, basename: (path as NSString).lastPathComponent, size: 100,
            modifiedAt: Date(timeIntervalSince1970: 100), kind: .movie, library: .movies,
            title: "Film", year: 2020, seriesTitle: nil, seriesKey: nil, season: nil, episode: nil,
            movieKey: "film-2020", movieTitleKey: "film"
        )
    }

    func testParserRecognizesCaseInsensitiveConventionsAndRejectsGIF() {
        XCTAssertEqual(ShareMediaParser.localInventoryVersion, 2)
        XCTAssertEqual(ShareArtworkNameParser.parse("POSTER-2.EN.JPEG")?.role, .poster)
        XCTAssertEqual(ShareArtworkNameParser.parse("POSTER-2.EN.JPEG")?.numberedAlternative, 2)
        XCTAssertEqual(ShareArtworkNameParser.parse("POSTER-2.EN.JPEG")?.language, "en")
        XCTAssertEqual(ShareArtworkNameParser.parse("Movie - S01E01 - Pilot-thumb.webp")?.role, .episodeThumbnail)
        XCTAssertEqual(ShareArtworkNameParser.parse("season-specials-banner.png")?.season, 0)
        XCTAssertTrue(ShareArtworkNameParser.parse("season-specials-banner.png")?.isSpecialsSeason == true)
        XCTAssertEqual(ShareArtworkNameParser.parse("season 1-poster.tbn")?.season, 1)
        XCTAssertEqual(ShareArtworkNameParser.parse("season01-poster-2.jpg")?.season, 1)
        XCTAssertEqual(ShareArtworkNameParser.parse("season01-poster-2.jpg")?.numberedAlternative, 2)
        XCTAssertNil(ShareArtworkNameParser.parse("poster.gif"))
    }

    func testCoordinatorForwardsOnlyAcceptedPreferredAccountRevisionToArtworkCache() async {
        let lifecycle = CacheLifecycleSpy()
        let coordinator = ShareCatalogCoordinator(artworkCacheLifecycle: lifecycle)

        await coordinator.setPreferredAccountKeys(["active"], revision: 2)
        await coordinator.setPreferredAccountKeys(["stale"], revision: 1)

        let preferences = await lifecycle.recordedPreferences()
        XCTAssertEqual(
            preferences,
            [.init(accountKeys: ["active"], revision: 2)]
        )
    }

    func testAssociationFailsClosedForAmbiguousMovieFolderAndSharesLogicalMovieOwner() {
        let artwork = candidate("Movies/Film/poster.jpg")
        let one = ShareArtworkCatalogAsset(
            relPath: "Movies/Film/Film 1080p.mkv", kind: .movie,
            movieOwnerID: "f:Movies/Film/Film 1080p.mkv", seriesKey: nil, season: nil, metadataRoot: nil
        )
        let two = ShareArtworkCatalogAsset(
            relPath: "Movies/Film/Other.mkv", kind: .movie,
            movieOwnerID: "f:Movies/Film/Other.mkv", seriesKey: nil, season: nil, metadataRoot: nil
        )
        XCTAssertTrue(ShareArtworkAssociationPolicy.associations(candidate: artwork, assets: [one, two]).isEmpty)

        let version = ShareArtworkCatalogAsset(
            relPath: "Movies/Film/Film 4K.mkv", kind: .movie,
            movieOwnerID: one.movieOwnerID, seriesKey: nil, season: nil, metadataRoot: nil
        )
        let associated = ShareArtworkAssociationPolicy.associations(candidate: artwork, assets: [one, version])
        XCTAssertEqual(associated.map(\.itemID), [one.movieOwnerID])
        XCTAssertEqual(associated.map(\.placement), [.poster])
    }

    func testUnmatchedExactStemImageFailsClosedInOtherwiseUnambiguousMovieFolder() {
        let artwork = candidate("Movies/Film/vacation.jpg")
        let asset = ShareArtworkCatalogAsset(
            relPath: "Movies/Film/Film.mkv", kind: .movie,
            movieOwnerID: "f:Movies/Film/Film.mkv", seriesKey: nil, season: nil, metadataRoot: nil
        )

        XCTAssertTrue(
            ShareArtworkAssociationPolicy.associations(candidate: artwork, assets: [asset]).isEmpty
        )
    }

    func testSeasonNamedArtworkAssociatesWithSeasonBeforeExactStemMatching() {
        let artwork = candidate("Shows/Series/season01-poster.jpg")
        let episode = ShareArtworkCatalogAsset(
            relPath: "Shows/Series/Season 01/Series - S01E01.mkv",
            kind: .episode,
            movieOwnerID: nil,
            seriesKey: "series",
            season: 1,
            metadataRoot: "Shows/Series"
        )

        XCTAssertEqual(
            ShareArtworkAssociationPolicy.associations(candidate: artwork, assets: [episode]),
            [
                ShareArtworkAssociation(
                    itemID: ShareCatalogID.season("series", 1),
                    placement: .seasonPoster,
                    artworkRelPath: artwork.relPath,
                    rank: 0
                )
            ]
        )
    }

    func testExactStemAndSeasonAssociationStayInsideOwnerDirectoryTree() {
        let movieArtwork = candidate("Movies/Foo/Film-poster.jpg")
        let otherMovie = ShareArtworkCatalogAsset(
            relPath: "Movies/Other/Film.mkv",
            kind: .movie,
            movieOwnerID: "f:Movies/Other/Film.mkv",
            seriesKey: nil,
            season: nil,
            metadataRoot: nil
        )
        XCTAssertTrue(
            ShareArtworkAssociationPolicy.associations(
                candidate: movieArtwork,
                assets: [otherMovie]
            ).isEmpty
        )

        let seasonArtwork = candidate("Shows/Foo/season01-poster.jpg")
        let otherSeriesEpisode = ShareArtworkCatalogAsset(
            relPath: "Shows/Foobar/Season 01/Foobar - S01E01.mkv",
            kind: .episode,
            movieOwnerID: nil,
            seriesKey: "foobar",
            season: 1,
            metadataRoot: "Shows/Foobar"
        )
        XCTAssertTrue(
            ShareArtworkAssociationPolicy.associations(
                candidate: seasonArtwork,
                assets: [otherSeriesEpisode]
            ).isEmpty
        )
    }

    func testBackdropFolderCapIsStableAcrossTransportListingOrder() throws {
        let entries = try (0..<40).map { index in
            try RemoteFileEntry(
                relativePath: "fanart-\(index).jpg",
                kind: .file,
                size: 100,
                modifiedAt: Date(timeIntervalSince1970: 100)
            )
        }
        let forward = ShareArtworkInventoryPolicy.candidates(
            entries: entries,
            parentDir: "Movies/Film/extrafanart"
        )
        let reversed = ShareArtworkInventoryPolicy.candidates(
            entries: Array(entries.reversed()),
            parentDir: "Movies/Film/extrafanart"
        )

        XCTAssertEqual(forward.count, ShareArtworkInventoryPolicy.perSubfolderCap)
        XCTAssertEqual(forward.map(\.relPath), reversed.map(\.relPath))
    }

    func testRankingUsesDistinctDetailFallbackOnlyWhenAvailable() {
        let home = [ShareArtworkRankedCandidate(relPath: "a", rank: 0)]
        let detail = [
            ShareArtworkRankedCandidate(relPath: "a", rank: 0),
            ShareArtworkRankedCandidate(relPath: "b", rank: 1),
        ]
        XCTAssertEqual(ShareArtworkRankingPolicy.distinctDetail(home: home, detail: detail).map(\.relPath), ["b", "a"])
        XCTAssertEqual(ShareArtworkRankingPolicy.distinctDetail(home: home, detail: [detail[0]]).map(\.relPath), ["a"])
    }

    func testHomePrefersLandscapeWhileDetailPrefersBackdrop() {
        let asset = ShareArtworkCatalogAsset(
            relPath: "Movies/Film/Film.mkv", kind: .movie,
            movieOwnerID: "f:Movies/Film/Film.mkv", seriesKey: nil, season: nil, metadataRoot: nil
        )
        let landscape = ShareArtworkAssociationPolicy.associations(
            candidate: candidate("Movies/Film/landscape.jpg"),
            assets: [asset]
        )
        let backdrop = ShareArtworkAssociationPolicy.associations(
            candidate: candidate("Movies/Film/fanart.jpg"),
            assets: [asset]
        )

        let home = (landscape + backdrop).filter { $0.placement == .homeHero }.sorted { $0.rank < $1.rank }
        let detail = (landscape + backdrop).filter { $0.placement == .detailBackdrop }.sorted { $0.rank < $1.rank }
        XCTAssertEqual(home.first?.artworkRelPath, "Movies/Film/landscape.jpg")
        XCTAssertEqual(detail.first?.artworkRelPath, "Movies/Film/fanart.jpg")
    }

    func testOnlineArtworkPreferenceOffKeepsLocalArtworkFirst() throws {
        let onlineURL = try XCTUnwrap(URL(string: "https://example.invalid/online.jpg"))
        let localURL = try XCTUnwrap(URL(string: "https://example.invalid/local.jpg"))
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        item.posterURL = onlineURL
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)

        let projected = ShareCatalogReadProjection.applyLocalArtwork(
            item,
            [ArtworkSelection(placement: .poster, references: [.remote(localURL)])]
        )

        XCTAssertEqual(projected.artworkReferences(for: .poster), [.remote(localURL), .remote(onlineURL)])
        XCTAssertEqual(projected.metadataProvenance[.posterURL]?.source, .localArtwork)
    }

    func testOnlineArtworkPreferenceOverridesOnlyArtwork() throws {
        let onlineURL = try XCTUnwrap(URL(string: "https://example.invalid/online.jpg"))
        let localURL = try XCTUnwrap(URL(string: "https://example.invalid/local.jpg"))
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        item.overview = "Online overview"
        item.posterURL = onlineURL
        item.metadataProvenance[.overview] = MetadataAttribution(source: .wikipedia)
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)

        let localOverviewJSON = String(
            decoding: try JSONEncoder().encode("Local overview"),
            as: UTF8.self
        )
        let withLocalText = ShareCatalogReadProjection.applyLocalMetadata(
            item,
            [
                .overview: .init(
                    source: .localNFO,
                    valueJSON: localOverviewJSON
                )
            ]
        )
        let projected = ShareCatalogReadProjection.applyLocalArtwork(
            withLocalText,
            [ArtworkSelection(placement: .poster, references: [.remote(localURL)])],
            metadataConfig: MetadataEnrichmentConfig(preferOnlineArtwork: true)
        )

        XCTAssertEqual(projected.artworkReferences(for: .poster), [.remote(onlineURL)])
        XCTAssertEqual(projected.metadataProvenance[.posterURL]?.source, .tmdb)
        XCTAssertEqual(projected.overview, "Local overview")
        XCTAssertEqual(projected.metadataProvenance[.overview]?.source, .localNFO)
    }

    func testDisabledOnlineProviderCannotOverrideLocalArtwork() throws {
        let onlineURL = try XCTUnwrap(URL(string: "https://example.invalid/online.jpg"))
        let localURL = try XCTUnwrap(URL(string: "https://example.invalid/local.jpg"))
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        item.posterURL = onlineURL
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        let config = MetadataEnrichmentConfig(
            disabledSources: [.tmdb],
            preferOnlineArtwork: true
        )

        let projected = ShareCatalogReadProjection.applyLocalArtwork(
            item,
            [ArtworkSelection(placement: .poster, references: [.remote(localURL)])],
            metadataConfig: config
        )

        XCTAssertEqual(projected.artworkReferences(for: .poster).first, .remote(localURL))
        XCTAssertEqual(projected.metadataProvenance[.posterURL]?.source, .localArtwork)
    }

    func testCatalogReadAppliesOnlineArtworkPreference() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = ShareCatalogStore(
            accountKey: fixture.accountKey,
            directory: fixture.directory,
            metadataConfig: { MetadataEnrichmentConfig(preferOnlineArtwork: true) }
        )
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        let asset = movie()
        let itemID = ShareCatalogID.file(asset.relPath)
        await store.upsert([asset], scanID: 1)
        let saved = await store.saveEnrichment(
            itemID: itemID,
            .init(posterURL: URL(string: "https://example.invalid/online.jpg")),
            version: ShareEnricher.version
        )
        XCTAssertTrue(saved)
        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)

        let loaded = await store.item(id: itemID)
        let item = try XCTUnwrap(loaded)
        XCTAssertEqual(
            item.artworkReferences(for: .poster),
            [.remote(try XCTUnwrap(URL(string: "https://example.invalid/online.jpg")))]
        )
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE source='localArtwork';"),
            1,
            "preference changes projection, not the independently persisted local lane"
        )
    }

    func testArtworkRoundTripIsPathFreeInProvenanceAndDoesNotTouchExternalLane() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!)
        )
        let asset = movie()
        await store.upsert([asset], scanID: 1)
        let itemID = ShareCatalogID.file(asset.relPath)
        let saved = await store.saveEnrichment(
            itemID: itemID,
            .init(posterURL: URL(string: "https://example.invalid/external.jpg")),
            version: ShareEnricher.version
        )
        XCTAssertTrue(saved)
        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)

        let item = await store.item(id: itemID)
        XCTAssertEqual(item?.artworkReferences(for: .poster).count, 2)
        XCTAssertEqual(item?.metadataProvenance[.posterURL]?.source, .localArtwork)
        XCTAssertNil(item?.metadataProvenance[.posterURL]?.sourceURL)
        XCTAssertNil(try fixture.text("""
            SELECT source_url FROM metadata_values
            WHERE item_id='\(itemID)' AND source='localArtwork' LIMIT 1;
            """))
        let storedSelection = try XCTUnwrap(fixture.text("""
            SELECT value_json FROM metadata_values
            WHERE item_id='\(itemID)' AND source='localArtwork' LIMIT 1;
            """))
        XCTAssertFalse(storedSelection.contains("Movies/Film/poster.jpg"))
        XCTAssertFalse(storedSelection.contains("relativePath"))
        XCTAssertTrue(storedSelection.contains("catalogArtworkID"))
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM enrichment WHERE item_id='\(itemID)';"), 1)
        guard case .networkFile(let localReference) = try XCTUnwrap(
            item?.artworkReferences(for: .poster).first
        ) else {
            return XCTFail("Expected local artwork first")
        }
        let encodedItem = try JSONEncoder().encode(try XCTUnwrap(item))
        XCTAssertFalse(
            String(decoding: encodedItem, as: UTF8.self)
                .contains("Movies/Film/poster.jpg")
        )
        let locator = await store.artworkLocator(for: localReference)
        XCTAssertEqual(locator?.relativePath, "Movies/Film/poster.jpg")

        let refreshed = await store.saveEnrichment(
            itemID: itemID,
            .init(posterURL: URL(string: "https://example.invalid/refreshed.jpg")),
            version: ShareEnricher.version
        )
        XCTAssertTrue(refreshed)
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE source='localArtwork';"),
            1,
            "external replacement must preserve the independently owned local artwork lane"
        )
        let refreshedItem = await store.item(id: itemID)
        XCTAssertEqual(refreshedItem?.artworkReferences(for: .poster).count, 2)

        // A clean scan where the media remains but the sidecar is absent deletes
        // only the local artwork lane; external enrichment stays intact.
        await store.upsert([asset], scanID: 2)
        let finalized = await store.finalizeCleanScan(inScan: 2)
        XCTAssertTrue(finalized)
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM local_artwork_files;"), 0)
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE source='localArtwork';"), 0)
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM enrichment WHERE item_id='\(itemID)';"), 1)
    }

    func testCleanReassociationRemovesSelectionFromFormerOwner() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        let original = movie("Movies/Film/Film.mkv")
        await store.upsert([original], scanID: 1)
        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)
        let oldOwner = ShareCatalogID.file(original.relPath)
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE item_id='\(oldOwner)' AND source='localArtwork';"),
            1
        )

        let newRepresentative = movie("Movies/Film/A Film.mkv")
        await store.upsert([original, newRepresentative], scanID: 2)
        try fixture.execute("UPDATE local_artwork_files SET last_scan=2;")
        let finalized = await store.finalizeCleanScan(inScan: 2)
        XCTAssertTrue(finalized)

        let newOwner = ShareCatalogID.file(newRepresentative.relPath)
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE item_id='\(oldOwner)' AND source='localArtwork';"),
            0
        )
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE item_id='\(newOwner)' AND source='localArtwork';"),
            1
        )
    }

    func testPartialUpdateNeverPrunesObservedArtwork() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let asset = movie()
        await store.upsert([asset], scanID: 1)
        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)
        await store.upsert([asset], scanID: 2)
        XCTAssertEqual(try fixture.integer("SELECT COUNT(*) FROM local_artwork_files;"), 1)
        XCTAssertEqual(try fixture.integer("SELECT probe_status='pending' FROM local_artwork_files;"), 1)
    }

    func testLaterAssetBatchAssociatesPreviouslyInventoriedSeriesArtwork() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        await store.upsertArtwork([candidate("Shows/Series/poster.jpg")], scanID: 1)
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE source='localArtwork';"),
            0
        )

        let seriesKey = ShareCatalogID.seriesKey(fromTitle: "Series")
        let episode = CatalogAsset(
            relPath: "Shows/Series/Season 01/Series - S01E01.mkv",
            basename: "Series - S01E01.mkv",
            size: 100,
            modifiedAt: Date(timeIntervalSince1970: 100),
            kind: .episode,
            library: .tv,
            title: "Pilot",
            year: nil,
            seriesTitle: "Series",
            seriesKey: seriesKey,
            season: 1,
            episode: 1,
            metadataRoot: "Shows/Series"
        )
        await store.upsert([episode], scanID: 1)

        let seriesItems = await store.series(in: .tv, offset: 0, limit: 10)
        let series = try XCTUnwrap(seriesItems.first)
        guard case .networkFile = try XCTUnwrap(
            series.artworkReferences(for: .poster).first
        ) else {
            return XCTFail("Expected the later asset batch to associate root artwork")
        }
    }

    func testIncrementalArtworkAssociationMaterializesOnlyRelevantCatalogRows() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        var assets = [movie()]
        assets.append(contentsOf: (0..<1_000).map { index in
            let path = "Movies/Unrelated \(index)/Unrelated \(index).mkv"
            return CatalogAsset(
                relPath: path,
                basename: (path as NSString).lastPathComponent,
                size: 100,
                modifiedAt: Date(timeIntervalSince1970: 100),
                kind: .movie,
                library: .movies,
                title: "Unrelated \(index)",
                year: 2020,
                seriesTitle: nil,
                seriesKey: nil,
                season: nil,
                episode: nil,
                movieKey: "unrelated-\(index)",
                movieTitleKey: "unrelated-\(index)"
            )
        })
        await store.upsert(assets, scanID: 1)
        await store.resetArtworkAssociationMaterializationStats()

        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)

        let stats = await store.currentArtworkAssociationMaterializationStats()
        XCTAssertEqual(stats.passes, 1, "one incremental artwork batch performs one bounded association pass")
        XCTAssertEqual(stats.assetRowsLoaded, 1, "unrelated catalog rows must never be materialized")
        XCTAssertEqual(stats.maximumRowsPerPass, 1)
        let item = await store.item(id: ShareCatalogID.file("Movies/Film/Film.mkv"))
        XCTAssertFalse(try XCTUnwrap(item).artworkReferences(for: .poster).isEmpty)

        await store.upsert(assets, scanID: 2)
        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 2)
        await store.resetArtworkAssociationMaterializationStats()
        let finalized = await store.finalizeCleanScan(inScan: 2)

        XCTAssertTrue(finalized)
        let finalizationStats = await store.currentArtworkAssociationMaterializationStats()
        XCTAssertEqual(finalizationStats.passes, 1, "clean finalization groups artwork by owner scope")
        XCTAssertEqual(
            finalizationStats.assetRowsLoaded,
            1,
            "clean finalization must not recreate a catalog-wide Cartesian materialization"
        )
        XCTAssertEqual(finalizationStats.maximumRowsPerPass, 1)
    }

    func testCredentialRotationRestampsReferencesWithoutRescan() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let first = CredentialRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000111"))
        )
        let second = CredentialRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000222"))
        )
        let asset = movie()
        let itemID = ShareCatalogID.file(asset.relPath)
        await store.configureArtworkReferenceContext(accountID: "art-account", credentialRevision: first)
        await store.upsert([asset], scanID: 1)
        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)
        let loadedFirstItem = await store.item(id: itemID)
        let firstItem = try XCTUnwrap(loadedFirstItem)
        guard case .networkFile(let firstReference) = try XCTUnwrap(
            firstItem.artworkReferences(for: .poster).first
        ) else {
            return XCTFail("Expected an initial network-file artwork reference")
        }

        await store.configureArtworkReferenceContext(accountID: "art-account", credentialRevision: second)

        let loadedItem = await store.item(id: itemID)
        let item = try XCTUnwrap(loadedItem)
        guard case .networkFile(let reference) = try XCTUnwrap(
            item.artworkReferences(for: .poster).first
        ) else {
            return XCTFail("Expected a network-file artwork reference")
        }
        XCTAssertEqual(reference.credentialRevision, second)
        XCTAssertEqual(reference.catalogArtworkID, firstReference.catalogArtworkID)
        let staleLocator = await store.artworkLocator(for: firstReference)
        let currentLocator = await store.artworkLocator(for: reference)
        XCTAssertNil(staleLocator)
        XCTAssertEqual(currentLocator?.relativePath, "Movies/Film/poster.jpg")
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM local_artwork_files;"),
            1,
            "credential rotation must rematerialize catalog state without rereading artwork"
        )
    }

    func testUnknownOpaqueArtworkReferenceFailsClosed() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let revision = CredentialRevision()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: revision
        )
        let reference = try NetworkArtworkReference(
            accountID: "art-account",
            credentialRevision: revision,
            catalogArtworkID: "art-unknown",
            representation: RemoteFileRepresentation(
                size: 100,
                identity: RemoteFileIdentity(
                    kind: .modificationTime,
                    modifiedAt: Date(timeIntervalSince1970: 100)
                ),
                consistency: .changeDetecting
            ),
            sourceRevision: "unknown"
        )

        let locator = await store.artworkLocator(for: reference)
        XCTAssertNil(locator)
    }

    func testUnvalidatedArtworkCannotBecomeHeroButSafePlacementsRemain() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        let asset = movie()
        await store.upsert([asset], scanID: 1)
        await store.upsertArtwork(
            [
                candidate("Movies/Film/fanart.jpg"),
                candidate("Movies/Film/poster.jpg"),
                candidate("Movies/Film/logo.png"),
            ],
            scanID: 1
        )

        let pendingItem = await store.item(id: ShareCatalogID.file(asset.relPath))
        let pending = try XCTUnwrap(pendingItem)
        XCTAssertTrue(pending.artworkReferences(for: .homeHero).isEmpty)
        XCTAssertTrue(pending.artworkReferences(for: .detailBackdrop).isEmpty)
        XCTAssertFalse(pending.artworkReferences(for: .poster).isEmpty)
        XCTAssertFalse(pending.artworkReferences(for: .logo).isEmpty)

        let probeFiles = await store.pendingArtworkProbes(limit: 10)
        for file in probeFiles {
            await store.setArtworkProbeResult(
                file,
                result: file.relPath.hasSuffix("fanart.jpg")
                    ? .incomplete
                    : .validated(width: 1_000, height: 1_500, contentType: "image/jpeg")
            )
        }
        let incompleteItem = await store.item(id: ShareCatalogID.file(asset.relPath))
        let incomplete = try XCTUnwrap(incompleteItem)
        XCTAssertTrue(incomplete.artworkReferences(for: .homeHero).isEmpty)
        XCTAssertTrue(incomplete.artworkReferences(for: .detailBackdrop).isEmpty)
        XCTAssertFalse(incomplete.artworkReferences(for: .poster).isEmpty)
        XCTAssertFalse(incomplete.artworkReferences(for: .logo).isEmpty)

        let fanart = try XCTUnwrap(
            probeFiles.first(where: { $0.relPath.hasSuffix("fanart.jpg") })
        )
        await store.setArtworkProbeResult(
            fanart,
            result: .validated(width: 1_920, height: 1_080, contentType: "image/jpeg")
        )
        let validatedItem = await store.item(id: ShareCatalogID.file(asset.relPath))
        let validated = try XCTUnwrap(validatedItem)
        XCTAssertFalse(validated.artworkReferences(for: .homeHero).isEmpty)
        XCTAssertFalse(validated.artworkReferences(for: .detailBackdrop).isEmpty)
    }

    func testCredentialRecoveryRevivesOnlyTransientlyExhaustedProbes() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        let asset = movie()
        await store.upsert([asset], scanID: 1)
        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)

        for _ in 0..<ShareCatalogStore.maxArtworkProbeAttempts {
            let pending = await store.pendingArtworkProbes(limit: 1)
            let file = try XCTUnwrap(pending.first)
            await store.recordArtworkProbeTransientFailure(file)
        }
        XCTAssertEqual(
            try fixture.text("SELECT probe_status FROM local_artwork_files;"),
            "transientExhausted"
        )
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE source='localArtwork';"),
            0
        )

        await store.resetArtworkProbeTransientFailures()

        XCTAssertEqual(try fixture.text("SELECT probe_status FROM local_artwork_files;"), "pending")
        XCTAssertEqual(try fixture.integer("SELECT probe_attempts FROM local_artwork_files;"), 0)
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE source='localArtwork';"),
            1
        )
    }

    func testSeriesPosterProjectsToSeriesCardsAndEpisodeFallback() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        let seriesKey = ShareCatalogID.seriesKey(fromTitle: "Series")
        let episode = CatalogAsset(
            relPath: "Shows/Series/Season 01/Series - S01E01.mkv",
            basename: "Series - S01E01.mkv",
            size: 100,
            modifiedAt: Date(timeIntervalSince1970: 100),
            kind: .episode,
            library: .tv,
            title: "Pilot",
            year: nil,
            seriesTitle: "Series",
            seriesKey: seriesKey,
            season: 1,
            episode: 1,
            metadataRoot: "Shows/Series"
        )
        await store.upsert([episode], scanID: 1)
        await store.upsertArtwork([candidate("Shows/Series/poster.jpg")], scanID: 1)

        let seriesItems = await store.series(in: .tv, offset: 0, limit: 10)
        let series = try XCTUnwrap(seriesItems.first)
        let episodeItems = await store.episodes(seriesKey: seriesKey, season: 1)
        let loadedEpisode = try XCTUnwrap(episodeItems.first)
        guard case .networkFile(let seriesReference) = try XCTUnwrap(
            series.artworkReferences(for: .poster).first
        ), case .networkFile(let episodeReference) = try XCTUnwrap(
            loadedEpisode.artworkReferences(for: .seriesPoster).first
        ) else {
            return XCTFail("Expected local series poster references")
        }
        XCTAssertEqual(seriesReference.sourceRevision, episodeReference.sourceRevision)
    }

    func testStrongIDSeriesMergeReassociatesLocalArtworkToCanonicalSeries() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        let loserKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinder")
        let canonicalKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinders")
        func episode(path: String, title: String, key: String, root: String) -> CatalogAsset {
            CatalogAsset(
                relPath: path,
                basename: (path as NSString).lastPathComponent,
                size: 100,
                modifiedAt: Date(timeIntervalSince1970: 100),
                kind: .episode,
                library: .tv,
                title: "Pilot",
                year: nil,
                seriesTitle: title,
                seriesKey: key,
                season: 1,
                episode: 1,
                metadataRoot: root
            )
        }
        await store.upsert([
            episode(
                path: "Shows/Peaky Blinder/S01E01.mkv",
                title: "Peaky Blinder",
                key: loserKey,
                root: "Shows/Peaky Blinder"
            ),
            episode(
                path: "Shows/Peaky Blinders/S01E01.mkv",
                title: "Peaky Blinders",
                key: canonicalKey,
                root: "Shows/Peaky Blinders"
            ),
        ], scanID: 1)
        await store.upsertArtwork([
            candidate("Shows/Peaky Blinder/poster.jpg"),
            candidate("Shows/Peaky Blinders/poster.jpg"),
        ], scanID: 1)

        let loserSaved = await store.saveEnrichment(
            itemID: ShareCatalogID.series(loserKey),
            .init(providerIDs: ["Tvdb": "270261"], title: "Peaky Blinders"),
            version: ShareEnricher.version
        )
        let canonicalSaved = await store.saveEnrichment(
            itemID: ShareCatalogID.series(canonicalKey),
            .init(providerIDs: ["Tvdb": "270261"], title: "Peaky Blinders"),
            version: ShareEnricher.version
        )
        XCTAssertTrue(loserSaved)
        XCTAssertTrue(canonicalSaved)

        let seriesItems = await store.series(in: .tv, offset: 0, limit: 10)
        let series = try XCTUnwrap(seriesItems.first)
        XCTAssertEqual(seriesItems.count, 1)
        XCTAssertFalse(series.artworkReferences(for: .poster).isEmpty)
        XCTAssertEqual(
            try fixture.integer("""
                SELECT COUNT(*) FROM local_artwork_associations
                WHERE item_id='\(ShareCatalogID.series(loserKey))';
                """),
            0
        )
        XCTAssertGreaterThan(
            try fixture.integer("""
                SELECT COUNT(*) FROM local_artwork_associations
                WHERE item_id='\(ShareCatalogID.series(canonicalKey))';
                """),
            0
        )
    }

    func testArtworkReferenceContextRelaunchWithSameRevisionIsNoOp() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let revision = CredentialRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000333"))
        )
        let asset = movie()
        let itemID = ShareCatalogID.file(asset.relPath)
        let firstStore = fixture.makeStore()
        await firstStore.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: revision
        )
        await firstStore.upsert([asset], scanID: 1)
        await firstStore.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)
        let before = try fixture.text("""
            SELECT value_json FROM metadata_values
            WHERE item_id='\(itemID)' AND field='artwork.poster' AND source='localArtwork';
            """)
        let marker = try fixture.text("""
            SELECT value FROM meta WHERE key='artwork_reference_context_v2';
            """)

        // A new store models a process relaunch. The persisted marker must avoid a
        // synchronous catalog-wide rematerialization when account + revision match.
        let relaunchedStore = fixture.makeStore()
        await relaunchedStore.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: revision
        )

        XCTAssertEqual(
            try fixture.text("""
                SELECT value_json FROM metadata_values
                WHERE item_id='\(itemID)' AND field='artwork.poster' AND source='localArtwork';
                """),
            before
        )
        XCTAssertEqual(
            try fixture.text("SELECT value FROM meta WHERE key='artwork_reference_context_v2';"),
            marker
        )
    }

    func testRejectingExactFingerprintResurfacesExternalFallbackUntilFileChanges() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        let asset = movie()
        let itemID = ShareCatalogID.file(asset.relPath)
        await store.upsert([asset], scanID: 1)
        let saved = await store.saveEnrichment(
            itemID: itemID,
            .init(posterURL: URL(string: "https://example.invalid/external.jpg")),
            version: ShareEnricher.version
        )
        XCTAssertTrue(saved)
        await store.upsertArtwork([candidate("Movies/Film/poster.jpg")], scanID: 1)
        let loadedBefore = await store.item(id: itemID)
        let before = try XCTUnwrap(loadedBefore)
        guard case .networkFile(let rejected) = try XCTUnwrap(
            before.artworkReferences(for: .poster).first
        ) else {
            return XCTFail("Expected a network-file artwork reference")
        }

        await store.rejectArtworkReference(rejected)

        let loadedFallback = await store.item(id: itemID)
        let fallback = try XCTUnwrap(loadedFallback)
        XCTAssertEqual(
            fallback.artworkReferences(for: .poster),
            [.remote(try XCTUnwrap(URL(string: "https://example.invalid/external.jpg")))]
        )
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM metadata_values WHERE source='localArtwork';"),
            0
        )
        XCTAssertEqual(
            try fixture.integer("SELECT COUNT(*) FROM enrichment WHERE item_id='\(itemID)';"),
            1
        )

        await store.upsertArtwork(
            [candidate("Movies/Film/poster.jpg", etag: "\"art-2\"")],
            scanID: 2
        )
        let loadedChanged = await store.item(id: itemID)
        let changed = try XCTUnwrap(loadedChanged)
        guard case .networkFile(let replacement) = try XCTUnwrap(
            changed.artworkReferences(for: .poster).first
        ) else {
            return XCTFail("Expected changed artwork to become eligible again")
        }
        XCTAssertNotEqual(replacement.sourceRevision, rejected.sourceRevision)
    }

    func testWeakArtworkRevisionChangesWithScanGeneration() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(
            accountID: "art-account",
            credentialRevision: CredentialRevision()
        )
        let asset = movie()
        let itemID = ShareCatalogID.file(asset.relPath)
        let weakCandidate = candidate("Movies/Film/poster.jpg", etag: nil)
        await store.upsert([asset], scanID: 1)
        await store.upsertArtwork([weakCandidate], scanID: 1)
        let loadedFirstItem = await store.item(id: itemID)
        let firstItem = try XCTUnwrap(loadedFirstItem)
        guard case .networkFile(let firstReference) = try XCTUnwrap(
            firstItem.artworkReferences(for: .poster).first
        ) else {
            return XCTFail("Expected weak network-file artwork")
        }

        await store.upsertArtwork([weakCandidate], scanID: 2)
        let loadedSecondItem = await store.item(id: itemID)
        let secondItem = try XCTUnwrap(loadedSecondItem)
        guard case .networkFile(let secondReference) = try XCTUnwrap(
            secondItem.artworkReferences(for: .poster).first
        ) else {
            return XCTFail("Expected rescanned weak network-file artwork")
        }

        XCTAssertNotEqual(firstReference.sourceRevision, secondReference.sourceRevision)
        await store.rejectArtworkReference(firstReference)
        let loadedAfterStaleRejection = await store.item(id: itemID)
        XCTAssertFalse(
            try XCTUnwrap(loadedAfterStaleRejection)
                .artworkReferences(for: .poster)
                .isEmpty,
            "a stale weak-generation rejection must not remove the current reference"
        )
        await store.rejectArtworkReference(secondReference)
        let loadedAfterCurrentRejection = await store.item(id: itemID)
        XCTAssertTrue(
            try XCTUnwrap(loadedAfterCurrentRejection)
                .artworkReferences(for: .poster)
                .isEmpty
        )
    }

    func testValidatedUltraWideArtworkIsExcludedFromHeroesButBannerRemains() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.configureArtworkReferenceContext(accountID: "art-account", credentialRevision: CredentialRevision())
        let asset = movie()
        await store.upsert([asset], scanID: 1)
        let fanart = candidate("Movies/Film/fanart.jpg")
        let banner = candidate("Movies/Film/banner.jpg")
        await store.upsertArtwork([fanart, banner], scanID: 1)
        let pending = await store.pendingArtworkProbes(limit: 10)
        for file in pending {
            await store.setArtworkProbeResult(
                file,
                result: .validated(
                    width: file.relPath.hasSuffix("fanart.jpg") ? 6_000 : 6_000,
                    height: file.relPath.hasSuffix("fanart.jpg") ? 1_000 : 1_000,
                    contentType: "image/jpeg"
                )
            )
        }
        let loadedItem = await store.item(id: ShareCatalogID.file(asset.relPath))
        let item = try XCTUnwrap(loadedItem)
        XCTAssertTrue(item.artworkReferences(for: .homeHero).isEmpty)
        XCTAssertTrue(item.artworkReferences(for: .detailBackdrop).isEmpty)
        XCTAssertFalse(item.artworkReferences(for: .banner).isEmpty)
    }
}
