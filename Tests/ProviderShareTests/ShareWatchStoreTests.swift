import XCTest
@testable import ProviderShare
import CoreModels

/// Decisive coverage for the share's *local* watch state — the seam Plex/Jellyfin
/// never needed because their watch state lives server-side. These tests answer
/// the on-device question directly: does a resume written during playback survive
/// an app relaunch (a fresh `ShareWatchStore` reading the same file), and does it
/// surface in the Continue Watching feed (`resumable`)?
final class ShareWatchStoreTests: XCTestCase {
    private func makeDurableStore(
        maximumPayloadBytes: Int =
            DurableLocalStateStore.defaultMaximumPayloadBytes
    ) throws -> DurableLocalStateStore {
        try DurableLocalStateStore(
            secureStore: ShareWatchMemoryStore(),
            maximumPayloadBytes: maximumPayloadBytes
        )
    }

    /// The core "gone after restart" reproduction: write a resume, then read it
    /// back through a BRAND-NEW store instance pointed at the same directory
    /// (exactly what a relaunch does — a fresh provider builds a fresh store).
    func testResumeSurvivesRestart() async throws {
        let durableStore = try makeDurableStore()
        let itemID = "f:TV Shows/The Show/Season 01/S01E03.mkv"

        let live = ShareWatchStore(
            accountKey: "acct-1",
            durableStore: durableStore
        )
        await live.setResume(842, itemID: itemID, capturedAt: Date())

        // Simulate a relaunch: nothing shared in memory, only the file on disk.
        let afterRestart = ShareWatchStore(
            accountKey: "acct-1",
            durableStore: durableStore
        )
        let record = await afterRestart.record(for: itemID)
        XCTAssertEqual(record?.position, 842, "resume position must persist to disk across a fresh store")
        XCTAssertEqual(record?.played, false)
    }

    /// The Continue Watching feed is backed by `resumable`; an in-progress item
    /// must appear there after a relaunch.
    func testResumableSurfacesAfterRestart() async throws {
        let durableStore = try makeDurableStore()
        let itemID = "f:Movies/Some Movie (2021).mkv"

        let live = ShareWatchStore(
            accountKey: "acct-2",
            durableStore: durableStore
        )
        await live.setResume(300, itemID: itemID, capturedAt: Date())

        let afterRestart = ShareWatchStore(
            accountKey: "acct-2",
            durableStore: durableStore
        )
        let resumable = await afterRestart.resumable(limit: 10)
        XCTAssertEqual(resumable.map(\.itemID), [itemID], "an in-progress item must be resumable after restart")
    }

    /// A finished item clears its resume and drops out of the resumable feed.
    func testPlayedClearsResume() async throws {
        let durableStore = try makeDurableStore()
        let itemID = "f:Movies/Done (2020).mkv"

        let store = ShareWatchStore(
            accountKey: "acct-3",
            durableStore: durableStore
        )
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
        let durableStore = try makeDurableStore()
        let a = ShareWatchStore(
            accountKey: "acct-A",
            durableStore: durableStore
        )
        let b = ShareWatchStore(
            accountKey: "acct-B",
            durableStore: durableStore
        )
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
        let durableStore = try makeDurableStore()
        let itemID = "f:Movies/Ordering (2019).mkv"
        let store = ShareWatchStore(
            accountKey: "acct-4",
            durableStore: durableStore
        )

        let newer = Date()
        let older = newer.addingTimeInterval(-60)
        await store.setResume(900, itemID: itemID, capturedAt: newer)
        await store.setResume(100, itemID: itemID, capturedAt: older) // stale: must be ignored

        let record = await store.record(for: itemID)
        XCTAssertEqual(record?.position, 900, "a stale write must not overwrite newer state")
    }

    /// A resume written with a known duration persists that duration across a
    /// relaunch, so the Continue Watching progress bar (position / duration) can be
    /// rendered without re-playing the item.
    func testDurationPersistsAcrossRestart() async throws {
        let durableStore = try makeDurableStore()
        let itemID = "f:Movies/Timed (2022).mkv"

        let live = ShareWatchStore(
            accountKey: "acct-5",
            durableStore: durableStore
        )
        await live.setResume(600, itemID: itemID, capturedAt: Date(), duration: 6000)

        let afterRestart = ShareWatchStore(
            accountKey: "acct-5",
            durableStore: durableStore
        )
        let record = await afterRestart.record(for: itemID)
        XCTAssertEqual(record?.position, 600)
        XCTAssertEqual(record?.duration, 6000, "duration must persist so the progress bar survives a relaunch")
    }

    /// A subsequent resume tick that lacks duration (e.g. an outbox-drained write
    /// with no live player) must not wipe a previously-learned duration.
    func testResumeWithoutDurationPreservesLearnedDuration() async throws {
        let durableStore = try makeDurableStore()
        let itemID = "f:Movies/Kept (2023).mkv"
        let store = ShareWatchStore(
            accountKey: "acct-6",
            durableStore: durableStore
        )

        await store.setResume(100, itemID: itemID, capturedAt: Date(), duration: 5000)
        await store.setResume(200, itemID: itemID, capturedAt: Date().addingTimeInterval(1)) // no duration

        let record = await store.record(for: itemID)
        XCTAssertEqual(record?.position, 200)
        XCTAssertEqual(record?.duration, 5000, "a duration-less resume must keep the previously-learned duration")
    }

    func testLongPathsPruneOldestRecordsToDurableByteBudget() async throws {
        let durableStore = try makeDurableStore(
            maximumPayloadBytes: 4_096
        )
        let store = ShareWatchStore(
            accountKey: "bounded",
            durableStore: durableStore
        )
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<100 {
            await store.setResume(
                TimeInterval(index + 1),
                itemID: "f:" + String(repeating: "directory/", count: 8)
                    + "episode-\(index).mkv",
                capturedAt: start.addingTimeInterval(TimeInterval(index))
            )
        }

        let afterRestart = ShareWatchStore(
            accountKey: "bounded",
            durableStore: durableStore
        )
        let records = await afterRestart.recordsSnapshot()

        XCTAssertLessThan(records.count, 100)
        XCTAssertNotNil(
            records[
                "f:" + String(repeating: "directory/", count: 8)
                    + "episode-99.mkv"
            ]
        )
        XCTAssertNil(
            records[
                "f:" + String(repeating: "directory/", count: 8)
                    + "episode-0.mkv"
            ]
        )
    }

    private final class ShareWatchMemoryStore:
        SecureStoring,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func setString(_ value: String, for key: String) throws {
            lock.lock()
            storage[key] = value
            lock.unlock()
        }

        func string(for key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func readString(for key: String) throws -> String? {
            string(for: key)
        }

        func removeValue(for key: String) throws {
            lock.lock()
            storage[key] = nil
            lock.unlock()
        }
    }
}
