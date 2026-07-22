import XCTest
@testable import MetadataKit

/// Locks the Step 6 additions to ``MetadataDiskCache``: current-byte-size accounting,
/// a user-adjustable budget that evicts immediately, and clear-all.
final class MetadataDiskCacheByteSizeTests: XCTestCase {
    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-metadata-bytesize-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testCurrentByteSizeGrowsWithEntriesAndResetsAfterClear() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MetadataDiskCache(directory: directory)

        let empty = await cache.currentByteSize()
        for i in 0..<20 {
            await cache.store(URL(string: "https://example.com/\(i).jpg"), for: "key-\(i)")
        }
        let filled = await cache.currentByteSize()
        XCTAssertGreaterThan(filled, empty)

        await cache.clear()
        let cleared = await cache.currentByteSize()
        XCTAssertLessThan(cleared, filled)
        let clearedHit = await cache.cached("key-0")
        XCTAssertNil(clearedHit ?? nil)
    }

    func testSetMaxBytesEvictsImmediately() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MetadataDiskCache(directory: directory)

        for i in 0..<40 {
            await cache.store(URL(string: "https://example.com/poster-\(i).jpg"), for: "poster-\(i)")
        }
        let before = await cache.currentByteSize()
        XCTAssertGreaterThan(before, 0)

        // Lower the budget well under the current size; eviction must run at once.
        let tightBudget = before / 3
        await cache.setMaxBytes(tightBudget)
        let after = await cache.currentByteSize()
        XCTAssertLessThan(after, before)
        XCTAssertLessThanOrEqual(after, tightBudget + 64) // small serialization slack
    }

    func testRaisingBudgetKeepsData() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MetadataDiskCache(directory: directory, maxBytes: 4 * 1024 * 1024)
        await cache.store(URL(string: "https://example.com/a.jpg"), for: "a")
        await cache.setMaxBytes(16 * 1024 * 1024)
        // Raising the cap never drops a fresh entry.
        let hit = await cache.cached("a")
        XCTAssertEqual(hit ?? nil, URL(string: "https://example.com/a.jpg"))
    }
}
