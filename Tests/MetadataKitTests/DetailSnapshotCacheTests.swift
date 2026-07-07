import XCTest
import CoreModels
@testable import MetadataKit

final class DetailSnapshotCacheTests: XCTestCase {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testStoresAndRestoresSnapshotAcrossInstances() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let series = MediaItem(id: "series-1", title: "Jane the Virgin", kind: .series)
        let season = MediaItem(id: "season-4", title: "Season 4", kind: .season)
        let episode = MediaItem(id: "ep-1", title: "Chapter 1", kind: .episode)
        let sources = [
            MediaSourceRef(accountID: "a", itemID: "series-1"),
            MediaSourceRef(accountID: "b", itemID: "x99")
        ]
        let snapshot = DetailSnapshotCache.Snapshot(
            item: series,
            children: [season],
            seasonEpisodes: ["season-4": [episode]],
            sources: sources
        )

        let writer = DetailSnapshotCache(directory: dir)
        await writer.store(snapshot, for: "acct|series-1")

        // A *fresh* instance (simulating a new app launch) restores it from disk.
        let reader = DetailSnapshotCache(directory: dir)
        let restored = await reader.snapshot(for: "acct|series-1")
        XCTAssertEqual(restored?.item.id, "series-1")
        XCTAssertEqual(restored?.children.map(\.id), ["season-4"])
        XCTAssertEqual(restored?.seasonEpisodes["season-4"]?.map(\.id), ["ep-1"])
        XCTAssertEqual(restored?.sources.count, 2)
    }

    func testMissReturnsNil() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DetailSnapshotCache(directory: dir)
        let restored = await cache.snapshot(for: "acct|unknown")
        XCTAssertNil(restored)
    }

    func testExpiredSnapshotIsDropped() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = DetailSnapshotCache.Snapshot(
            item: MediaItem(id: "m1", title: "Old", kind: .movie),
            children: []
        )
        // Zero max-age ⇒ anything already saved is immediately stale.
        let cache = DetailSnapshotCache(directory: dir, maxAge: 0)
        await cache.store(snapshot, for: "k")
        let restored = await cache.snapshot(for: "k")
        XCTAssertNil(restored)
    }

    func testPrunesLeastRecentlyUsedBeyondCap() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DetailSnapshotCache(directory: dir, maxEntries: 2)
        for index in 0..<5 {
            let snap = DetailSnapshotCache.Snapshot(
                item: MediaItem(id: "m\(index)", title: "Movie \(index)", kind: .movie),
                children: []
            )
            await cache.store(snap, for: "key-\(index)")
        }
        // `store` runs the LRU prune off the write path on a separate serial queue,
        // so the directory isn't guaranteed pruned the instant the last `store`
        // returns. Await the pending prune deterministically (a sentinel on that
        // serial queue runs after every enqueued prune) instead of racing it.
        await cache.awaitPendingPrune()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("plozz-detail-cache-v2"),
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertLessThanOrEqual(files.count, 2)
    }
}
