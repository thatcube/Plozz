import XCTest
@testable import ProviderShare
import CoreModels
import MediaTransportCore

final class ShareExtrasTests: XCTestCase {
    private actor FakeTree {
        let entries: [String: [RemoteFileEntry]]
        let failures: Set<String>
        private(set) var listed: [String] = []

        init(_ entries: [String: [RemoteFileEntry]], failures: Set<String> = []) {
            self.entries = entries
            self.failures = failures
        }

        func list(_ path: String) throws -> [RemoteFileEntry] {
            listed.append(path)
            if failures.contains(path) {
                throw MediaTransportError.protocolViolation(reason: "fixture failure")
            }
            return entries[path] ?? []
        }
    }

    private func dir(_ name: String) -> RemoteFileEntry {
        try! RemoteFileEntry(
            relativePath: name,
            kind: .directory,
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func file(_ name: String) -> RemoteFileEntry {
        try! RemoteFileEntry(
            relativePath: name,
            kind: .file,
            size: 1_000,
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
    }

    @discardableResult
    private func scan(
        _ tree: [String: [RemoteFileEntry]],
        store: ShareCatalogStore,
        failures: Set<String> = []
    ) async -> (ShareScanOutcome, FakeTree) {
        let fake = FakeTree(tree, failures: failures)
        let scanner = ShareScanner(store: store, concurrency: 2, makeLister: {
            ShareScanner.ScanLister(list: { try await fake.list($0) }, close: {})
        })
        return (await scanner.scan(), fake)
    }

    private func movieTree(includeTrailer: Bool = true) -> [String: [RemoteFileEntry]] {
        var tree: [String: [RemoteFileEntry]] = [
            "": [dir("Movies")],
            "Movies": [dir("The Film (2020)")],
            "Movies/The Film (2020)": [
                file("The Film (2020).mkv"),
                dir("Trailers"),
                dir("Extras"),
                dir("Bonus Features"),
            ],
            "Movies/The Film (2020)/Trailers": [
                file("Official Trailer.mkv"),
                file("Official Trailer.en.srt"),
            ],
            "Movies/The Film (2020)/Extras": [
                file("Commentary.mkv"),
                dir("Behind The Scenes"),
                dir("Nested"),
            ],
            "Movies/The Film (2020)/Extras/Behind The Scenes": [
                file("Making The Film.mkv"),
            ],
            "Movies/The Film (2020)/Extras/Nested": [
                file("must-not-be-walked.mkv"),
            ],
            "Movies/The Film (2020)/Bonus Features": [
                file("Long Bonus.mkv"),
            ],
        ]
        if !includeTrailer {
            tree["Movies/The Film (2020)"] = [file("The Film (2020).mkv")]
            tree.removeValue(forKey: "Movies/The Film (2020)/Trailers")
            tree.removeValue(forKey: "Movies/The Film (2020)/Extras")
            tree.removeValue(forKey: "Movies/The Film (2020)/Extras/Behind The Scenes")
            tree.removeValue(forKey: "Movies/The Film (2020)/Extras/Nested")
            tree.removeValue(forKey: "Movies/The Film (2020)/Bonus Features")
        }
        return tree
    }

    func testTerminalSuffixesAreExactAndSeparatorBound() {
        XCTAssertEqual(
            ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: "Movie - Trailer.mkv")?.kind,
            .trailer
        )
        XCTAssertEqual(
            ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: "Movie.behind_the_scenes.mp4")?.kind,
            .behindTheScenes
        )
        XCTAssertNil(
            ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: "MovieTrailer.mkv")
        )
        XCTAssertNil(
            ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: "Trailer Park.mkv")
        )
        XCTAssertNil(
            ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: "The Interview.mkv")
        )
        XCTAssertNil(
            ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: "The.Interview.2014.mkv")
        )
        XCTAssertEqual(
            ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: "Movie-behindthescenes.mkv")?.kind,
            .behindTheScenes
        )
        XCTAssertEqual(
            ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: "Movie-deleted.mkv")?.kind,
            .deletedScene
        )
        XCTAssertNil(
            ShareExtraDiscoveryPolicy.folderKind("Bonus Disc")
        )
        XCTAssertNil(ShareExtraDiscoveryPolicy.folderKind("Xtra"))
        XCTAssertNotNil(ShareExtraDiscoveryPolicy.folderKind("Xtras"))
        XCTAssertNil(
            ShareExtraDiscoveryPolicy.terminalSuffix(inFileName: "Movie-xtra.mkv")
        )
        XCTAssertEqual(
            ShareExtraDiscoveryPolicy.resumeBehavior(
                forItemID: "f:Movies/Film/Extras/Trailers/Preview.mkv"
            ),
            false
        )
        XCTAssertFalse(
            ShareExtraDiscoveryPolicy.movieFolderProvesOwner(
                "Film Sequel",
                titleKey: "film",
                year: nil
            )
        )
        let ownerAsset = ShareScanner.asset(
            relPath: "Movies/The Film (2020)/The Film (2020).mkv",
            entry: file("The Film (2020).mkv")
        )
        XCTAssertEqual(
            ShareScanner.provenLocalOwnerFile(
                in: "Movies/The Film (2020)",
                assets: [ownerAsset]
            ),
            "Movies/The Film (2020)/The Film (2020).mkv"
        )
    }

    func testTypedExtraDirectoryProducesOnlyExtraCandidates() async {
        let extraFile = file("Official Trailer.mkv")
        let result = await ShareScanner.processDirectory(
            ShareScanner.FrontierEntry(
                relPath: "Movies/Film/Trailers",
                extraTraversal: ShareExtraTraversal(
                    ownerPath: "Movies/Film",
                    ownerFileRelPath: "Movies/Film/Film.mkv",
                    defaultKind: .trailer,
                    permitsTypedChildren: false
                )
            ),
            using: ShareScanner.ScanLister(
                list: { _ in [extraFile] },
                close: {}
            )
        )

        XCTAssertEqual(result.assets, [])
        XCTAssertEqual(result.extras.count, 1)
        XCTAssertEqual(result.extras.first?.kind, .trailer)
    }

    func testMovieDirectoryProducesBoundedExtraFrontiers() async {
        let movie = file("Film (2020).mkv")
        let trailers = dir("Trailers")
        let result = await ShareScanner.processDirectory(
            ShareScanner.FrontierEntry(relPath: "Movies/Film (2020)"),
            using: ShareScanner.ScanLister(
                list: { _ in [movie, trailers] },
                close: {}
            )
        )

        XCTAssertEqual(result.assets.count, 1)
        XCTAssertEqual(result.subdirectories.count, 1)
        XCTAssertEqual(
            result.subdirectories.first?.frontier.extraTraversal?.ownerFileRelPath,
            "Movies/Film (2020)/Film (2020).mkv"
        )
    }

    func testMovieExtrasStaySeparateAndTraversalIsBounded() async {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let (_, fake) = await scan(movieTree(), store: store)
        let movieID = ShareCatalogID.movie(
            ShareCatalogID.movieKey(fromTitle: "The Film", year: 2020)
        )

        let extras = await store.extras(ownerID: movieID)
        XCTAssertEqual(extras.count, 4)
        XCTAssertEqual(
            Set(extras.map(\.kind)),
            [.trailer, .behindTheScenes, .other]
        )
        XCTAssertTrue(extras.allSatisfy { $0.item.id.hasPrefix("f:") })
        XCTAssertFalse(extras.first(where: { $0.kind == .trailer })?.supportsResume ?? true)
        XCTAssertTrue(extras.first(where: { $0.kind == .behindTheScenes })?.supportsResume == true)

        let counts = await store.libraryCounts()
        let search = await store.search(query: "Trailer", limit: 10)
        let latest = await store.latest(limit: 10)
        XCTAssertEqual(counts.movies, 1)
        XCTAssertEqual(search, [])
        XCTAssertEqual(latest.map(\.title), ["The Film"])
        let listed = await fake.listed
        XCTAssertTrue(
            listed.contains("Movies/The Film (2020)/Trailers"),
            "listed paths: \(listed)"
        )
        XCTAssertFalse(listed.contains("Movies/The Film (2020)/Extras/Nested"))
    }

    func testPartialFirstScanKeepsResolvedExtrasWithoutPruning() async {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        var tree = movieTree()
        tree["", default: []].append(dir("Broken"))
        let (outcome, _) = await scan(tree, store: store, failures: ["Broken"])
        let count = await store.extraCount()
        let movieID = ShareCatalogID.movie(
            ShareCatalogID.movieKey(fromTitle: "The Film", year: 2020)
        )
        let extras = await store.extras(ownerID: movieID)

        XCTAssertEqual(outcome, .completedPartial)
        XCTAssertEqual(count, 4)
        XCTAssertEqual(extras.count, 4)
    }

    func testSeriesSeasonSpecialsEpisodeAndExplicitCollectionOwners() async {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("TV"), dir("Collections"), dir("Loose")],
            "TV": [dir("Show")],
            "TV/Show": [dir("Extras"), dir("Season 01"), dir("Specials")],
            "TV/Show/Extras": [file("Show Overview.mkv")],
            "TV/Show/Season 01": [
                file("Show.S01E01.mkv"),
                file("Show.S01E01-trailer.mkv"),
                dir("Featurettes"),
            ],
            "TV/Show/Season 01/Featurettes": [file("Season Feature.mkv")],
            "TV/Show/Specials": [
                file("Show.S00E01.mkv"),
                dir("Trailers"),
            ],
            "TV/Show/Specials/Trailers": [file("Special Preview.mkv")],
            "Collections": [dir("Favorites")],
            "Collections/Favorites": [dir("Trailers")],
            "Collections/Favorites/Trailers": [file("Collection Reel.mkv")],
            "Loose": [dir("Trailers")],
            "Loose/Trailers": [file("Orphan.mkv")],
        ]
        await scan(tree, store: store)

        let key = ShareCatalogID.seriesKey(fromTitle: "Show")
        let seriesExtras = await store.extras(ownerID: ShareCatalogID.series(key))
        let seasonExtras = await store.extras(ownerID: ShareCatalogID.season(key, 1))
        let specialsExtras = await store.extras(ownerID: ShareCatalogID.season(key, 0))
        let episodeExtras = await store.extras(
            ownerID: ShareCatalogID.file("TV/Show/Season 01/Show.S01E01.mkv")
        )
        let collectionExtras = await store.extras(ownerID: "d:Collections/Favorites")
        let looseExtras = await store.extras(ownerID: "d:Loose")
        let extraCount = await store.extraCount()
        let promoted = await store.item(
            id: ShareCatalogID.file("TV/Show/Season 01/Show.S01E01-trailer.mkv")
        )
        XCTAssertEqual(seriesExtras.count, 1)
        XCTAssertEqual(seasonExtras.count, 1)
        XCTAssertEqual(specialsExtras.count, 1)
        XCTAssertEqual(episodeExtras.map(\.kind), [.trailer])
        XCTAssertEqual(collectionExtras.count, 1)
        XCTAssertEqual(looseExtras, [])
        XCTAssertEqual(extraCount, 5)
        XCTAssertNil(promoted)
    }

    func testRootExtraFolderAndDirectorySymlinkAreNeverTraversed() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let symlink = try RemoteFileEntry(relativePath: "Trailers", kind: .symlink)
        let tree: [String: [RemoteFileEntry]] = [
            "": [dir("Extras"), dir("Movies")],
            "Extras": [file("orphan.mkv")],
            "Movies": [dir("Film (2020)")],
            "Movies/Film (2020)": [file("Film (2020).mkv"), symlink],
            "Movies/Film (2020)/Trailers": [file("must-not-be-read.mkv")],
        ]
        let (_, fake) = await scan(tree, store: store)

        let listed = await fake.listed
        let extraCount = await store.extraCount()
        XCTAssertFalse(listed.contains("Extras"))
        XCTAssertFalse(listed.contains("Movies/Film (2020)/Trailers"))
        XCTAssertEqual(extraCount, 0)
    }

    func testCleanScanPrunesButPartialScanPreservesExtras() async {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let movieID = ShareCatalogID.movie(
            ShareCatalogID.movieKey(fromTitle: "The Film", year: 2020)
        )
        await scan(movieTree(), store: store)
        let initialExtras = await store.extras(ownerID: movieID)
        XCTAssertEqual(initialExtras.count, 4)

        var partialTree = movieTree()
        partialTree["", default: []].append(dir("Broken"))
        let partial = await scan(
            partialTree,
            store: store,
            failures: ["Broken"]
        )
        let partialExtras = await store.extras(ownerID: movieID)
        XCTAssertEqual(partial.0, .completedPartial)
        XCTAssertEqual(partialExtras.count, 4)

        await scan(movieTree(includeTrailer: false), store: store)
        let prunedExtras = await store.extras(ownerID: movieID)
        let prunedCount = await store.extraCount()
        XCTAssertEqual(prunedExtras, [])
        XCTAssertEqual(prunedCount, 0)
    }

    func testManualInventoryUpgradeInvalidatesLegacyIncrementalLeafStamp() async {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await scan(movieTree(includeTrailer: false), store: store)
        await store.setMeta("local_inventory_version", "2")

        let fake = FakeTree(movieTree())
        let scanner = ShareScanner(store: store, concurrency: 2, makeLister: {
            ShareScanner.ScanLister(list: { try await fake.list($0) }, close: {})
        })
        let outcome = await scanner.scan()
        let movieID = ShareCatalogID.movie(
            ShareCatalogID.movieKey(fromTitle: "The Film", year: 2020)
        )
        let extras = await store.extras(ownerID: movieID)
        let listed = await fake.listed

        XCTAssertEqual(outcome, .completedClean)
        XCTAssertEqual(extras.count, 4)
        XCTAssertTrue(listed.contains("Movies/The Film (2020)"))
        XCTAssertTrue(listed.contains("Movies/The Film (2020)/Trailers"))
    }

    func testPartialUpgradeRemovesResolvedExtraFromLegacyAssets() async {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let ownerPath = "Movies/The Film (2020)"
        let ownerFile = "\(ownerPath)/The Film (2020).mkv"
        let extraPath = "\(ownerPath)/The Film (2020)-trailer.mkv"
        await store.upsert([
            ShareScanner.asset(relPath: ownerFile, entry: file("The Film (2020).mkv")),
            ShareScanner.asset(relPath: extraPath, entry: file("The Film (2020)-trailer.mkv")),
        ], scanID: 1)
        await store.upsertExtras([
            CatalogExtraCandidate(
                relPath: extraPath,
                parentDir: ownerPath,
                basename: "The Film (2020)-trailer.mkv",
                size: 1_000,
                modifiedAt: Date(timeIntervalSince1970: 100),
                kind: .trailer,
                title: "Trailer",
                ownerPath: ownerPath,
                ownerFileRelPath: ownerFile
            )
        ], scanID: 2)

        await store.resolveExtraOwners()

        let movieID = ShareCatalogID.movie(
            ShareCatalogID.movieKey(fromTitle: "The Film", year: 2020)
        )
        let extras = await store.extras(ownerID: movieID)
        let promoted = await store.item(id: ShareCatalogID.file(extraPath))
        XCTAssertEqual(extras.count, 1)
        XCTAssertNil(promoted)
    }

    func testCanonicalPathDeduplicatesEquivalentUnicodePaths() async {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let ownerPath = "Movies/Café (2020)"
        let ownerFile = "\(ownerPath)/Café (2020).mkv"
        let asset = ShareScanner.asset(
            relPath: ownerFile,
            entry: file("Café (2020).mkv")
        )
        await store.upsert([asset], scanID: 1)
        let composed = "\(ownerPath)/Trailers/Café Trailer.mkv"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        await store.upsertExtras([
            CatalogExtraCandidate(
                relPath: composed,
                parentDir: "\(ownerPath)/Trailers",
                basename: "Café Trailer.mkv",
                size: 1,
                modifiedAt: .distantPast,
                kind: .trailer,
                title: "Trailer",
                ownerPath: ownerPath,
                ownerFileRelPath: ownerFile
            ),
            CatalogExtraCandidate(
                relPath: decomposed,
                parentDir: "\(ownerPath)/Trailers".decomposedStringWithCanonicalMapping,
                basename: "Café Trailer.mkv".decomposedStringWithCanonicalMapping,
                size: 1,
                modifiedAt: .distantPast,
                kind: .trailer,
                title: "Trailer",
                ownerPath: ownerPath,
                ownerFileRelPath: ownerFile
            ),
        ], scanID: 1)
        await store.resolveExtraOwners()

        let count = await store.extraCount()
        XCTAssertEqual(count, 1)
    }

    func testLegacyStringFrontierDecodesWithExtraContext() throws {
        let data = try JSONEncoder().encode([
            "Movies/The Film (2020)",
            "Movies/The Film (2020)/Extras/Trailers",
        ])
        let decoded = try XCTUnwrap(ShareScanner.decodeFrontier(data))

        XCTAssertNil(decoded[0].extraTraversal)
        XCTAssertEqual(decoded[1].extraTraversal?.ownerPath, "Movies/The Film (2020)")
        XCTAssertEqual(decoded[1].extraTraversal?.defaultKind, .trailer)
    }

    func testSchemaMigratesToVersionFourWithSeparateExtrasTable() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        try fixture.execute("PRAGMA user_version=3;")
        _ = await fixture.makeStore().extraCount()

        XCTAssertEqual(try fixture.integer("PRAGMA user_version;"), 4)
        XCTAssertEqual(
            try fixture.integer(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='extras';"
            ),
            1
        )
    }

    func testShareResumeRulesAndTrailerCompatibility() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await scan(movieTree(), store: store)
        let movieID = ShareCatalogID.movie(
            ShareCatalogID.movieKey(fromTitle: "The Film", year: 2020)
        )
        let provider = ShareProvider(
            session: makeSession(),
            catalogStore: store
        )
        let extras = try await provider.extras(for: movieID)
        let trailer = try XCTUnwrap(extras.first(where: { $0.kind == .trailer }))
        let longExtra = try XCTUnwrap(extras.first(where: { $0.kind == .behindTheScenes }))

        try await provider.setResumePosition(30, itemID: trailer.item.id, capturedAt: Date())
        try await provider.setResumePosition(60, itemID: longExtra.item.id, capturedAt: Date())

        let refreshed = try await provider.extras(for: movieID)
        XCTAssertNil(refreshed.first(where: { $0.item.id == trailer.item.id })?.item.resumePosition)
        XCTAssertEqual(
            refreshed.first(where: { $0.item.id == longExtra.item.id })?.item.resumePosition,
            60
        )
        let continueWatching = try await provider.continueWatching(limit: 10)
        let trailers = try await provider.trailers(for: movieID)
        XCTAssertTrue(continueWatching.isEmpty)
        XCTAssertNil(trailers.first?.resumePosition)
        XCTAssertTrue(
            ShareProvider.sidecarMatchesVideo(
                sidecarStem: "Official Trailer",
                videoStem: "Official Trailer",
                dedicatedFolder: false
            )
        )
    }

    func testExtraPlaybackKeepsFileAddressAndUsesOnlyExactStemSidecars() async throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await scan(movieTree(), store: store)
        let movieKey = ShareCatalogID.movieKey(fromTitle: "The Film", year: 2020)
        let movieID = ShareCatalogID.movie(movieKey)
        let storedExtras = await store.extras(ownerID: movieID)
        let trailerID = try XCTUnwrap(
            storedExtras
                .first(where: { $0.kind == .trailer })?
                .item.id
        )
        let trailerPath = try XCTUnwrap(ShareCatalogID.relPath(forFileID: trailerID))
        try fixture.execute("""
        INSERT OR REPLACE INTO movie_alias(alias_id, group_key)
        VALUES('\(trailerID)', '\(movieKey)');
        """)
        let legacyCanonicalID = await store.canonicalItemID(trailerID)
        XCTAssertEqual(legacyCanonicalID, movieID)

        let fileSystem = ExtraPlaybackFileSystem(
            trailerPath: trailerPath,
            trailerDirectory: (trailerPath as NSString).deletingLastPathComponent
        )
        let session = ExtraPlaybackSession(fileSystem: fileSystem)
        let provider = ShareProvider(
            session: makeSession(),
            sessionFactory: { _ in session },
            catalogStore: store
        )

        let request = try await provider.playbackInfo(for: trailerID)
        guard case .networkFile(let locator)? = request.playbackSource else {
            return XCTFail("share extra must use network-file playback")
        }
        XCTAssertEqual(locator.relativePath, trailerPath)
        XCTAssertEqual(request.item.id, trailerID)
        XCTAssertEqual(request.item.kind, .video)
        XCTAssertEqual(request.subtitleTracks.count, 1)
        XCTAssertEqual(request.subtitleTracks.first?.language, "en")
    }

    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(
                id: "share:extras",
                name: "NAS",
                baseURL: URL(string: "smb://nas/Media")!,
                provider: .mediaShare
            ),
            userID: "guest",
            userName: "guest",
            deviceID: "tests",
            accessToken: ""
        )
    }

    private final class ExtraPlaybackSession: MediaTransportSession, @unchecked Sendable {
        let key: MediaTransportSessionKey
        let fileSystem: any MediaTransportFileSystem

        init(fileSystem: any MediaTransportFileSystem) {
            key = MediaTransportSessionKey(
                accountID: "share:extras",
                credentialRevision: CredentialRevision(),
                endpoint: try! MediaTransportEndpointIdentity(
                    transportIdentifier: "smb",
                    host: "nas",
                    rootPath: "/Media"
                ),
                trustRevision: UUID(),
                role: .metadata
            )
            self.fileSystem = fileSystem
        }

        func shutdown() async {}
        func isHealthy() async -> Bool { true }
    }

    private final class ExtraPlaybackFileSystem: MediaTransportFileSystem, @unchecked Sendable {
        private let trailerPath: String
        private let trailerDirectory: String

        init(trailerPath: String, trailerDirectory: String) {
            self.trailerPath = trailerPath
            self.trailerDirectory = trailerDirectory
        }

        func validate() async throws {}

        func probe() async throws -> MediaTransportProbe {
            MediaTransportProbe(
                capabilities: try MediaTransportCapabilities(
                    supportsList: true,
                    supportsStat: true,
                    supportsBoundedWholeFileRead: true,
                    byteRangeBehavior: .randomAccess,
                    maximumBoundedWholeFileReadBytes: 1_024,
                    consistency: .changeDetecting
                )
            )
        }

        func list(relativePath: String) async throws -> [RemoteFileEntry] {
            if relativePath == trailerDirectory {
                return [
                    try RemoteFileEntry(
                        relativePath: (trailerPath as NSString).lastPathComponent,
                        kind: .file,
                        size: 1_000,
                        modifiedAt: Date(timeIntervalSince1970: 100)
                    ),
                    try RemoteFileEntry(
                        relativePath: "Official Trailer.en.srt",
                        kind: .file,
                        size: 50,
                        modifiedAt: Date(timeIntervalSince1970: 100)
                    ),
                ]
            }
            if relativePath == "\(trailerDirectory)/Subs" {
                return [
                    try RemoteFileEntry(
                        relativePath: "Official Trailer Extended.en.srt",
                        kind: .file,
                        size: 50,
                        modifiedAt: Date(timeIntervalSince1970: 100)
                    ),
                ]
            }
            return []
        }

        func stat(relativePath: String) async throws -> RemoteFileEntry {
            try RemoteFileEntry(
                relativePath: relativePath,
                kind: .file,
                size: 1_000,
                modifiedAt: Date(timeIntervalSince1970: 100)
            )
        }

        func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
            Data("1\n00:00:00,000 --> 00:00:01,000\nHello\n".utf8)
        }

        func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
            throw MediaTransportError.unsupportedCapability("not needed")
        }
    }
}
