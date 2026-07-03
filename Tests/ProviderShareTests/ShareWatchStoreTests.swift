import XCTest
@testable import ProviderShare
import CoreModels

/// Decisive coverage for the share's *local* watch state — the seam Plex/Jellyfin
/// never needed because their watch state lives server-side. These tests answer
/// the on-device question directly: does a resume written during playback survive
/// an app relaunch (a fresh `ShareWatchStore` reading the same file), and does it
/// surface in the Continue Watching feed (`resumable`)?
final class ShareWatchStoreTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-watch-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The core "gone after restart" reproduction: write a resume, then read it
    /// back through a BRAND-NEW store instance pointed at the same directory
    /// (exactly what a relaunch does — a fresh provider builds a fresh store).
    func testResumeSurvivesRestart() async throws {
        let dir = makeTempDir()
        let itemID = "f:TV Shows/The Show/Season 01/S01E03.mkv"

        let live = ShareWatchStore(accountKey: "acct-1", directory: dir)
        await live.setResume(842, itemID: itemID, capturedAt: Date())

        // Simulate a relaunch: nothing shared in memory, only the file on disk.
        let afterRestart = ShareWatchStore(accountKey: "acct-1", directory: dir)
        let record = await afterRestart.record(for: itemID)
        XCTAssertEqual(record?.position, 842, "resume position must persist to disk across a fresh store")
        XCTAssertEqual(record?.played, false)
    }

    /// The Continue Watching feed is backed by `resumable`; an in-progress item
    /// must appear there after a relaunch.
    func testResumableSurfacesAfterRestart() async throws {
        let dir = makeTempDir()
        let itemID = "f:Movies/Some Movie (2021).mkv"

        let live = ShareWatchStore(accountKey: "acct-2", directory: dir)
        await live.setResume(300, itemID: itemID, capturedAt: Date())

        let afterRestart = ShareWatchStore(accountKey: "acct-2", directory: dir)
        let resumable = await afterRestart.resumable(limit: 10)
        XCTAssertEqual(resumable.map(\.itemID), [itemID], "an in-progress item must be resumable after restart")
    }

    /// A finished item clears its resume and drops out of the resumable feed.
    func testPlayedClearsResume() async throws {
        let dir = makeTempDir()
        let itemID = "f:Movies/Done (2020).mkv"

        let store = ShareWatchStore(accountKey: "acct-3", directory: dir)
        await store.setResume(500, itemID: itemID, capturedAt: Date())
        await store.setPlayed(true, itemID: itemID, capturedAt: Date().addingTimeInterval(1))

        let resumable = await store.resumable(limit: 10)
        let record = await store.record(for: itemID)
        XCTAssertTrue(resumable.isEmpty, "a played item is not resumable")
        XCTAssertEqual(record?.played, true)
    }

    /// Two shares/accounts keep separate files, so one account's watch state never
    /// bleeds into another's feed.
    func testAccountsAreIsolated() async throws {
        let dir = makeTempDir()
        let a = ShareWatchStore(accountKey: "acct-A", directory: dir)
        let b = ShareWatchStore(accountKey: "acct-B", directory: dir)
        await a.setResume(120, itemID: "f:x.mkv", capturedAt: Date())

        let aResumable = await a.resumable(limit: 10)
        let bResumable = await b.resumable(limit: 10)
        XCTAssertEqual(aResumable.count, 1)
        XCTAssertTrue(bResumable.isEmpty, "account B must not see account A's resume")
    }

    /// Ordering rule the store relies on: a stale (older `capturedAt`) write can't
    /// clobber a newer one — the mechanism that stops a late-draining queued write
    /// from resurrecting old state.
    func testStaleWriteIsRejected() async throws {
        let dir = makeTempDir()
        let itemID = "f:Movies/Ordering (2019).mkv"
        let store = ShareWatchStore(accountKey: "acct-4", directory: dir)

        let newer = Date()
        let older = newer.addingTimeInterval(-60)
        await store.setResume(900, itemID: itemID, capturedAt: newer)
        await store.setResume(100, itemID: itemID, capturedAt: older) // stale: must be ignored

        let record = await store.record(for: itemID)
        XCTAssertEqual(record?.position, 900, "a stale write must not overwrite newer state")
    }
}
