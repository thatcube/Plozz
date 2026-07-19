import XCTest
import CoreModels
@testable import MetadataKit

private final class DirectoryEnumerationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0

    var count: Int { lock.withLock { countStorage } }

    func contents(at directory: URL, keys: [URLResourceKey]) -> [URL]? {
        lock.withLock { countStorage += 1 }
        return try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        )
    }
}

/// Records enumerations and blocks inside the first (and every) directory scan until
/// explicitly released, so a test can hold a prune mid-enumeration and prove reads
/// are not serialized behind it.
private final class BlockingDirectoryEnumerationSpy: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var countStorage = 0

    var count: Int { lock.withLock { countStorage } }

    func contents(at directory: URL, keys: [URLResourceKey]) -> [URL]? {
        lock.withLock { countStorage += 1 }
        started.signal()
        release.wait()
        return try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        )
    }
}

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

    func testWriteBurstCoalescesIntoOneDirectoryScan() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = DirectoryEnumerationSpy()
        // A long debounce means no timer fires during the test; `awaitPendingPrune`
        // (the coordinator's deterministic settle) flushes the single coalesced
        // pending prune, so enumeration counts are exact.
        let cache = DetailSnapshotCache(
            directory: dir,
            maxEntries: 100,
            debounce: .seconds(1000),
            directoryContents: spy.contents
        )
        await cache.awaitPendingPrune()
        XCTAssertEqual(spy.count, 1, "startup prune performs exactly one directory scan")

        // A burst of writes coalesces into ONE pending prune rather than one scan
        // per write (the D3 behavior change).
        for index in 0..<50 {
            await cache.store(
                .init(
                    item: MediaItem(id: "m\(index)", title: "Movie \(index)", kind: .movie),
                    children: []
                ),
                for: "key-\(index)"
            )
        }
        await cache.awaitPendingPrune()
        XCTAssertEqual(
            spy.count,
            2,
            "a burst of 50 writes coalesces into a single directory scan"
        )

        // A later, separated burst schedules exactly one new prune.
        for index in 50..<80 {
            await cache.store(
                .init(
                    item: MediaItem(id: "m\(index)", title: "Movie \(index)", kind: .movie),
                    children: []
                ),
                for: "key-\(index)"
            )
        }
        await cache.awaitPendingPrune()
        XCTAssertEqual(
            spy.count,
            3,
            "a later separated burst schedules exactly one new directory scan"
        )
    }

    func testReadsProceedWhileAPruneIsBlocked() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed one snapshot on disk so the read under test has a real hit.
        let seeder = DetailSnapshotCache(directory: dir)
        await seeder.store(
            .init(item: MediaItem(id: "hit", title: "Hit", kind: .movie), children: []),
            for: "hit-key"
        )
        await seeder.awaitPendingPrune()

        let spy = BlockingDirectoryEnumerationSpy()
        let cache = DetailSnapshotCache(
            directory: dir,
            maxEntries: 100,
            debounce: .milliseconds(1),
            directoryContents: spy.contents
        )
        // The startup prune fires almost immediately and blocks mid-enumeration on
        // the coordinator's serial queue.
        spy.started.wait()

        // A read runs on the concurrent I/O queue and touches no directory
        // enumeration, so it must complete even though a prune is held. If reads
        // were serialized behind the prune this would hang until the test times out.
        let restored = await cache.snapshot(for: "hit-key")
        XCTAssertEqual(restored?.item.id, "hit")

        spy.release.signal()
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

    func testSerializedSnapshotNeverContainsLocalArtworkPath() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = "Private Library/Shows/Series/fanart.jpg"
        let accountID = "share-account"
        let reference = try NetworkArtworkReference(
            accountID: accountID,
            credentialRevision: CredentialRevision(),
            catalogArtworkID: "art-detail-snapshot",
            representation: RemoteFileRepresentation(
                size: 100,
                identity: RemoteFileIdentity(
                    kind: .modificationTime,
                    modifiedAt: Date(timeIntervalSince1970: 100)
                ),
                consistency: .changeDetecting
            ),
            sourceRevision: "opaque-revision"
        )
        let item = MediaItem(
            id: "private",
            title: "Private",
            kind: .series,
            artworkSelections: [
                ArtworkSelection(
                    placement: .detailBackdrop,
                    references: [.networkFile(reference)]
                )
            ]
        )
        let cache = DetailSnapshotCache(directory: dir)
        await cache.store(.init(item: item, children: []), for: "privacy")
        let data = try XCTUnwrap(
            try FileManager.default
                .contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                .first
                .flatMap {
                    try FileManager.default.contentsOfDirectory(
                        at: $0,
                        includingPropertiesForKeys: nil
                    ).first
                }
                .flatMap {
                    try FileManager.default.contentsOfDirectory(
                        at: $0,
                        includingPropertiesForKeys: nil
                    ).first
                }
                .map { try Data(contentsOf: $0) }
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains(path))
        XCTAssertFalse(text.contains("relativePath"))
        XCTAssertTrue(text.contains("catalogArtworkID"))
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
            at: dir.appendingPathComponent("plozz-detail-cache-v5").appendingPathComponent("default"),
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertLessThanOrEqual(files.count, 2)
    }

    func testPrunesLeastRecentlyUsedBeyondByteBudget() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let maxBytes = 6_000
        let cache = DetailSnapshotCache(
            directory: dir,
            maxEntries: 100,
            maxBytes: maxBytes
        )
        for index in 0..<8 {
            let snap = DetailSnapshotCache.Snapshot(
                item: MediaItem(
                    id: "m\(index)",
                    title: "Movie \(index)",
                    kind: .movie,
                    overview: String(repeating: "x", count: 2_000)
                ),
                children: []
            )
            await cache.store(snap, for: "byte-key-\(index)")
        }
        await cache.awaitPendingPrune()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("plozz-detail-cache-v5").appendingPathComponent("default"),
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let totalBytes = files.reduce(0) { partial, file in
            partial + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        XCTAssertLessThanOrEqual(totalBytes, maxBytes)
    }

    func testExistingDirectoryIsPrunedToByteBudgetOnInitialization() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = DetailSnapshotCache(
            directory: dir,
            maxEntries: 100,
            maxBytes: 1_000_000
        )
        for index in 0..<8 {
            await writer.store(.init(
                item: MediaItem(
                    id: "legacy-\(index)",
                    title: "Legacy \(index)",
                    kind: .movie,
                    overview: String(repeating: "y", count: 2_000)
                ),
                children: []
            ), for: "legacy-key-\(index)")
        }
        await writer.awaitPendingPrune()

        let maxBytes = 6_000
        let reader = DetailSnapshotCache(
            directory: dir,
            maxEntries: 100,
            maxBytes: maxBytes
        )
        await reader.awaitPendingPrune()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("plozz-detail-cache-v5").appendingPathComponent("default"),
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let totalBytes = files.reduce(0) { partial, file in
            partial + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        XCTAssertLessThanOrEqual(totalBytes, maxBytes)
    }
}
