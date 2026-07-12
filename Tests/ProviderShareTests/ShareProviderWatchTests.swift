import XCTest
@testable import ProviderShare
import CoreModels
import MediaTransportCore

/// End-to-end proof of the exact runtime path Brandon exercises on device:
/// the player's `reportPlayback(.progress)` ticks write local watch state, and
/// after an app relaunch (a brand-new `ShareProvider` for the same account) that
/// state must resurface both on the item detail (`item(id:)`) and in the Home
/// Continue Watching feed (`continueWatching`). The `ShareLibraryStore` never
/// touches the network for id → item reconstruction, so this needs no SMB server.
final class ShareProviderWatchTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-provider-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private final class LocatorFakeSession: MediaTransportSession, @unchecked Sendable {
        let key: MediaTransportSessionKey
        let fileSystem: any MediaTransportFileSystem = LocatorFakeFileSystem()

        init(revision: CredentialRevision) throws {
            key = MediaTransportSessionKey(
                accountID: "share:nas.local/Media",
                credentialRevision: revision,
                endpoint: try MediaTransportEndpointIdentity(
                    transportIdentifier: "smb",
                    host: "nas.local",
                    rootPath: "/Media"
                ),
                trustRevision: UUID(),
                role: .metadata
            )
        }

        func shutdown() async {}
    }

    private struct LocatorFakeFileSystem: MediaTransportFileSystem {
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
            []
        }

        func stat(relativePath: String) async throws -> RemoteFileEntry {
            try RemoteFileEntry(
                relativePath: relativePath,
                kind: .file,
                size: 42,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
            Data()
        }

        func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
            throw MediaTransportError.unsupportedCapability("test source")
        }
    }

    private func makeSession(
        baseURL: URL = URL(string: "smb://nas.local/Media")!,
        username: String = "guest",
        password: String = ""
    ) -> UserSession {
        let server = MediaServer(
            id: "share:nas.local/Media",
            name: "NAS",
            baseURL: baseURL,
            provider: .mediaShare
        )
        return UserSession(
            server: server,
            userID: "guest",
            userName: username,
            deviceID: "test-device",
            accessToken: password
        )
    }

    func testPlaybackLocatorIsRelativeToConfiguredSubfolderRoot() async throws {
        let revision = CredentialRevision()
        let session = try LocatorFakeSession(revision: revision)
        let provider = ShareProvider(
            session: makeSession(baseURL: URL(string: "smb://nas.local/Media/Movies")!),
            watchDirectory: makeTempDir(),
            credentialRevision: revision,
            sessionFactory: { _ in session }
        )

        let locator = try await provider.networkFileLocator(
            for: "Drama/Arrival.mkv"
        )

        XCTAssertEqual(locator.relativePath, "Drama/Arrival.mkv")
        XCTAssertEqual(locator.credentialRevision, revision)
        XCTAssertEqual(locator.representation.size, 42)
        XCTAssertEqual(locator.representation.consistency, .changeDetecting)
    }

    func testPlaybackLocatorContainsNoPasswordedGuestCredentials() async throws {
        let revision = CredentialRevision()
        let session = try LocatorFakeSession(revision: revision)
        let provider = ShareProvider(
            session: makeSession(username: "", password: "guest-secret"),
            watchDirectory: makeTempDir(),
            credentialRevision: revision,
            sessionFactory: { _ in session }
        )

        let locator = try await provider.networkFileLocator(for: "Arrival.mkv")

        XCTAssertNil(PlaybackSource.networkFile(locator).publicURL)
        XCTAssertFalse(
            PlaybackSource.networkFile(locator).redactedLabel.contains("guest-secret")
        )
    }

    func testAccountsOnSameEndpointKeepIndependentWatchState() async throws {
        let directory = makeTempDir()
        let session = makeSession()
        let first = ShareProvider(
            session: session,
            localMediaContext: LocalMediaContext(
                accountID: "account-a",
                profileID: "profile",
                profileNamespace: nil
            ),
            watchDirectory: directory
        )
        let second = ShareProvider(
            session: session,
            localMediaContext: LocalMediaContext(
                accountID: "account-b",
                profileID: "profile",
                profileNamespace: nil
            ),
            watchDirectory: directory
        )

        try await first.reportPlayback(
            PlaybackProgress(
                itemID: "f:Movie.mkv",
                playSessionID: "play",
                positionSeconds: 120,
                isPaused: false
            ),
            event: .progress
        )

        let firstItems = try await first.continueWatching(limit: 10)
        let secondItems = try await second.continueWatching(limit: 10)
        XCTAssertEqual(firstItems.count, 1)
        XCTAssertTrue(secondItems.isEmpty)
    }

    func testProfilesOnSameAccountKeepIndependentWatchState() async throws {
        let directory = makeTempDir()
        let session = makeSession()
        let first = ShareProvider(
            session: session,
            localMediaContext: LocalMediaContext(
                accountID: "account",
                profileID: "profile-a",
                profileNamespace: "household"
            ),
            watchDirectory: directory
        )
        let second = ShareProvider(
            session: session,
            localMediaContext: LocalMediaContext(
                accountID: "account",
                profileID: "profile-b",
                profileNamespace: "household"
            ),
            watchDirectory: directory
        )

        try await first.reportPlayback(
            PlaybackProgress(
                itemID: "f:Movie.mkv",
                playSessionID: "play",
                positionSeconds: 120,
                isPaused: false
            ),
            event: .progress
        )

        let firstItems = try await first.continueWatching(limit: 10)
        let secondItems = try await second.continueWatching(limit: 10)
        XCTAssertEqual(firstItems.count, 1)
        XCTAssertTrue(secondItems.isEmpty)
    }

    func testProgressTickPersistsAcrossRelaunch() async throws {
        let dir = makeTempDir()
        let session = makeSession()
        let itemID = "f:TV Shows/The Show/Season 01/S01E02.mkv"

        // Live playback: the engine progress timer fires ~every 10s.
        let live = ShareProvider(session: session, watchDirectory: dir)
        try await live.reportPlayback(
            PlaybackProgress(itemID: itemID, playSessionID: "s1", positionSeconds: 636, isPaused: false),
            event: .progress
        )

        // Relaunch: a fresh provider is built for the same account, memory empty.
        let afterRestart = ShareProvider(session: session, watchDirectory: dir)

        // 1) Detail page shows a Resume point.
        let detail = try await afterRestart.item(id: itemID)
        XCTAssertEqual(detail.resumePosition, 636, "detail must resume after relaunch")

        // 2) Continue Watching row surfaces the item.
        let cw = try await afterRestart.continueWatching(limit: 20)
        XCTAssertEqual(cw.map(\.id), [itemID], "item must appear in Continue Watching after relaunch")
        XCTAssertEqual(cw.first?.resumePosition, 636)
    }

    func testPauseAlsoPersists() async throws {
        let dir = makeTempDir()
        let session = makeSession()
        let itemID = "f:Movies/A Film (2022).mkv"

        let live = ShareProvider(session: session, watchDirectory: dir)
        try await live.reportPlayback(
            PlaybackProgress(itemID: itemID, playSessionID: "s2", positionSeconds: 120, isPaused: true),
            event: .pause
        )

        let afterRestart = ShareProvider(session: session, watchDirectory: dir)
        let cw = try await afterRestart.continueWatching(limit: 20)
        XCTAssertEqual(cw.map(\.id), [itemID], "a paused item must be resumable after relaunch")
    }

    /// A progress tick that carries the player's known duration must surface a
    /// `playedPercentage` on the Continue Watching card (which drives the progress
    /// bar) — and it must survive a relaunch.
    func testProgressWithDurationSurfacesPlayedPercentage() async throws {
        let dir = makeTempDir()
        let session = makeSession()
        let itemID = "f:Movies/Timed Film (2021).mkv"

        let live = ShareProvider(session: session, watchDirectory: dir)
        try await live.reportPlayback(
            PlaybackProgress(itemID: itemID, playSessionID: "s3", positionSeconds: 600, isPaused: false, durationSeconds: 6000),
            event: .progress
        )

        let afterRestart = ShareProvider(session: session, watchDirectory: dir)
        let cw = try await afterRestart.continueWatching(limit: 20)
        XCTAssertEqual(cw.map(\.id), [itemID])
        let pct = try XCTUnwrap(cw.first?.playedPercentage)
        XCTAssertEqual(pct, 0.1, accuracy: 0.001, "progress bar fraction must be position / duration after relaunch")
    }

    func testGroupedMovieRestoresLegacyFileWatchStateOnGridAndDetail() async throws {
        let watchDir = makeTempDir()
        let catalog = ShareCatalogStore(accountKey: "legacy-watch", directory: makeTempDir())
        let session = makeSession()
        let relPath = "Movies/Legacy Film (2020) 1080p.mkv"
        let movieKey = ShareCatalogID.movieKey(fromTitle: "Legacy Film", year: 2020)
        await catalog.upsert([
            CatalogAsset(
                relPath: relPath, basename: "Legacy Film (2020) 1080p.mkv",
                size: 1_000, modifiedAt: Date(), kind: .movie, library: .movies,
                title: "Legacy Film", year: 2020,
                seriesTitle: nil, seriesKey: nil, season: nil, episode: nil,
                movieKey: movieKey,
                movieTitleKey: ShareCatalogID.seriesKey(fromTitle: "Legacy Film")
            )
        ], scanID: 1)
        await catalog.rebuildMovieGroups()

        // Pre-upgrade state was persisted against the physical file id.
        let legacyID = ShareCatalogID.file(relPath)
        let watch = ShareWatchStore(
            localMediaContext: LocalMediaContext(
                accountID: session.server.id,
                profileID: ProfileStore.defaultProfileID,
                profileNamespace: nil
            ),
            directory: watchDir
        )
        await watch.setResume(600, itemID: legacyID, capturedAt: Date(), duration: 6_000)

        let provider = ShareProvider(
            session: session,
            watchDirectory: watchDir,
            catalogStore: catalog
        )
        let logicalID = ShareCatalogID.movie(movieKey)

        let detail = try await provider.item(id: logicalID)
        XCTAssertEqual(detail.resumePosition, 600)
        XCTAssertEqual(detail.playedPercentage ?? 0, 0.1, accuracy: 0.001)

        let page = try await provider.items(
            in: ShareCatalogID.moviesLibrary,
            kind: .movie,
            page: PageRequest(startIndex: 0, limit: 10)
        )
        XCTAssertEqual(page.items.map(\.id), [logicalID])
        XCTAssertEqual(page.items.first?.resumePosition, 600)
    }
}
