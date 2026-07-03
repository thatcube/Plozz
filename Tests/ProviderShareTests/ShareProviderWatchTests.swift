import XCTest
@testable import ProviderShare
import CoreModels

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
}
