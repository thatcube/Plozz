import XCTest
import Dispatch
@testable import MetadataKit

// MARK: - Instrumented seams

/// Records the queue each filesystem call ran on and the order of operations, so
/// tests can prove I/O executes on the dedicated serial executor (not the actor
/// or caller executor). Optionally blocks `read` until released.
private final class InstrumentedFileIO: MetadataDiskCache.FileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []
    private var onQueueStorage: [String: Bool] = [:]
    private var readCountStorage = 0
    private var writeCountStorage = 0
    private let readGate: DispatchSemaphore?

    init(blockReadUntilSignaled: DispatchSemaphore? = nil) {
        self.readGate = blockReadUntilSignaled
    }

    var events: [String] { lock.withLock { eventsStorage } }
    var readCount: Int { lock.withLock { readCountStorage } }
    var writeCount: Int { lock.withLock { writeCountStorage } }
    func ranOnDedicatedQueue(_ op: String) -> Bool { lock.withLock { onQueueStorage[op] ?? false } }

    private func record(_ op: String) {
        let onQueue = DispatchQueue.getSpecific(key: MetadataCacheFileIO.queueMarker) == true
        lock.withLock {
            eventsStorage.append(op)
            onQueueStorage[op] = onQueue
        }
    }

    func removeSupersededCaches(in directory: URL, currentFileName: String, filePrefix: String) {
        record("cleanup")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent != currentFileName
            && file.lastPathComponent.hasPrefix(filePrefix)
            && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func read(from url: URL) -> Data? {
        record("read")
        lock.withLock { readCountStorage += 1 }
        readGate?.wait()
        return try? Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) {
        record("write")
        lock.withLock { writeCountStorage += 1 }
        try? data.write(to: url, options: .atomic)
    }
}

/// Counts whole-map encodes/decodes to prove the encode count is bounded.
private final class CountingCoding: MetadataDiskCache.Coding, @unchecked Sendable {
    private let lock = NSLock()
    private var encodeCountStorage = 0
    private var decodeCountStorage = 0
    var encodeCount: Int { lock.withLock { encodeCountStorage } }
    var decodeCount: Int { lock.withLock { decodeCountStorage } }

    func decode(_ data: Data) -> [String: MetadataDiskCache.Entry]? {
        lock.withLock { decodeCountStorage += 1 }
        return try? JSONDecoder().decode([String: MetadataDiskCache.Entry].self, from: data)
    }

    func encode(_ entries: [String: MetadataDiskCache.Entry]) -> Data? {
        lock.withLock { encodeCountStorage += 1 }
        return try? JSONEncoder().encode(entries)
    }
}

/// An unrelated actor used to prove the cache's blocked I/O does not stall other
/// cooperative work.
private actor UnrelatedActor {
    private(set) var counter = 0
    func bump() { counter += 1 }
    func value() -> Int { counter }
}

final class MetadataDiskCacheConcurrencyTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-diskcache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheFileSize(in directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: - Off-actor serial execution

    func testFilesystemCallbacksRunOnDedicatedSerialQueue() async {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileIO = InstrumentedFileIO()
        let cache = MetadataDiskCache(directory: directory, maxBytes: 100_000, fileIO: fileIO, coding: CountingCoding())

        _ = await cache.cached("x")
        await cache.store(URL(string: "https://example.com/a.jpg"), for: "a")

        XCTAssertTrue(fileIO.ranOnDedicatedQueue("cleanup"), "cleanup must run on the dedicated I/O queue")
        XCTAssertTrue(fileIO.ranOnDedicatedQueue("read"), "read must run on the dedicated I/O queue")
        XCTAssertTrue(fileIO.ranOnDedicatedQueue("write"), "write must run on the dedicated I/O queue")
    }

    func testCleanupCompletesBeforeCurrentFileReadOnSameExecutor() async {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try? Data("legacy".utf8).write(to: directory.appendingPathComponent("plozz-metadata-cache-v1.json"))
        try? Data("{}".utf8).write(to: directory.appendingPathComponent("plozz-metadata-cache-v3.json"))
        let fileIO = InstrumentedFileIO()
        let cache = MetadataDiskCache(directory: directory, maxBytes: 100_000, fileIO: fileIO, coding: CountingCoding())

        _ = await cache.cached("x")

        let events = fileIO.events
        let cleanupIndex = events.firstIndex(of: "cleanup")
        let readIndex = events.firstIndex(of: "read")
        XCTAssertNotNil(cleanupIndex)
        XCTAssertNotNil(readIndex)
        XCTAssertLessThan(cleanupIndex!, readIndex!, "cleanup must finish before the current-file read")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("plozz-metadata-cache-v1.json").path),
            "the superseded file must be deleted during cleanup"
        )
    }

    func testNoSynchronousIOInInit() {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try? Data("legacy".utf8).write(to: directory.appendingPathComponent("plozz-metadata-cache-v1.json"))
        let fileIO = InstrumentedFileIO()
        _ = MetadataDiskCache(directory: directory, maxBytes: 100_000, fileIO: fileIO, coding: CountingCoding())

        // Construction alone must touch the filesystem seam zero times: cleanup is
        // deferred to the first load on the serial executor.
        XCTAssertTrue(fileIO.events.isEmpty, "init must perform no filesystem work; got \(fileIO.events)")
    }

    // MARK: - Blocked I/O + shared single load

    func testBlockedLoadIsSharedAndDoesNotStallUnrelatedActor() async {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        try? Data("{}".utf8).write(to: directory.appendingPathComponent("plozz-metadata-cache-v3.json"))
        let gate = DispatchSemaphore(value: 0)
        let fileIO = InstrumentedFileIO(blockReadUntilSignaled: gate)
        let cache = MetadataDiskCache(directory: directory, maxBytes: 100_000, fileIO: fileIO, coding: CountingCoding())

        // Two concurrent cache reads that both trigger the initial (blocked) load.
        let load1 = Task { await cache.cached("k1") }
        let load2 = Task { await cache.cached("k2") }

        // Wait until the (single) initial read has actually reached the blocked
        // filesystem call before making assertions.
        var spins = 0
        while fileIO.readCount == 0 && spins < 500 {
            try? await Task.sleep(nanoseconds: 2_000_000)
            spins += 1
        }
        XCTAssertEqual(fileIO.readCount, 1, "the initial load's read must be in-flight and shared")

        // While the load is parked on the I/O queue, an unrelated actor keeps making
        // progress — proving the actor executor is not blocked.
        let unrelated = UnrelatedActor()
        for _ in 0..<50 { await unrelated.bump() }
        let progressed = await unrelated.value()
        XCTAssertEqual(progressed, 50, "an unrelated actor must keep running while cache load is blocked")

        // The blocked initial load is shared: read must have been attempted exactly once.
        XCTAssertEqual(fileIO.readCount, 1, "concurrent callers must share ONE initial load, not read twice")

        gate.signal()
        _ = await load1.value
        _ = await load2.value
        XCTAssertEqual(fileIO.readCount, 1, "no extra read happens after the shared load completes")
    }

    // MARK: - Ordered writes

    func testConcurrentStoresPersistNewestStateWithoutStaleOverwrite() async {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MetadataDiskCache(directory: directory, maxBytes: 1_000_000)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    await cache.store(URL(string: "https://example.com/\(index).jpg"), for: "key-\(index)")
                }
            }
        }

        // Every mutation must survive on disk: a stale (lower-revision) completion
        // must never clobber newer state.
        let url = directory.appendingPathComponent("plozz-metadata-cache-v3.json")
        let data = try? Data(contentsOf: url)
        XCTAssertNotNil(data)
        let decoded = (try? JSONDecoder().decode([String: MetadataDiskCache.Entry].self, from: data!)) ?? [:]
        XCTAssertEqual(decoded.count, 40, "all concurrent stores must be represented in the final file")
        for index in 0..<40 {
            XCTAssertNotNil(decoded["key-\(index)"], "key-\(index) was lost to a stale overwrite")
        }
    }

    // MARK: - TTL + reopen preserved

    func testPositiveNegativeTTLAndReopenBehaviorUnchanged() async {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MetadataDiskCache(directory: directory, maxBytes: 1_000_000)
        await cache.store(URL(string: "https://example.com/poster.jpg"), for: "pos")
        await cache.store(nil, for: "neg")

        let pos = await cache.cached("pos")
        let neg = await cache.cached("neg")
        let miss = await cache.cached("absent")
        XCTAssertEqual(pos??.absoluteString, "https://example.com/poster.jpg")
        XCTAssertNotNil(neg, "a fresh negative is a remembered hit")
        XCTAssertEqual(neg!, URL?.none, "a negative resolves to .some(nil)")
        XCTAssertNil(miss, "an unknown key is a miss")

        // Reopen a fresh actor over the same directory: persisted entries reload.
        let reopened = MetadataDiskCache(directory: directory, maxBytes: 1_000_000)
        let reloadedPos = await reopened.cached("pos")
        XCTAssertEqual(reloadedPos??.absoluteString, "https://example.com/poster.jpg")

        // An already-expired entry is not returned and is dropped on load.
        let expiredDir = tempDir()
        defer { try? FileManager.default.removeItem(at: expiredDir) }
        let past = Date().addingTimeInterval(-10)
        let expiredEntry = ["stale": MetadataDiskCache.Entry(url: "https://example.com/x.jpg", expires: past)]
        let expiredData = try! JSONEncoder().encode(expiredEntry)
        try! expiredData.write(to: expiredDir.appendingPathComponent("plozz-metadata-cache-v3.json"))
        let expiredCache = MetadataDiskCache(directory: expiredDir, maxBytes: 1_000_000)
        let staleHit = await expiredCache.cached("stale")
        XCTAssertNil(staleHit, "an expired entry must be a miss")
    }

    // MARK: - Budget + bounded encodes

    func testOversizedStoresStayWithinBudgetKeepingNewestExpiring() async {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let maxBytes = 2_000
        let cache = MetadataDiskCache(directory: directory, maxBytes: maxBytes)
        for index in 0..<40 {
            let payload = String(repeating: "\(index)z", count: 60)
            await cache.store(URL(string: "https://example.com/\(index)/\(payload)")!, for: "key-\(index)")
        }
        XCTAssertLessThanOrEqual(cacheFileSize(in: directory), maxBytes, "pruning must keep the file within budget")

        // The most-recently stored (latest-expiring) key must survive eviction.
        let latest = await cache.cached("key-39")
        XCTAssertNotNil(latest, "newest-expiring entry must be retained by the eviction policy")
    }

    func testWholeMapEncodeCountIsBoundedRegardlessOfEntryCount() async throws {
        for count in [10, 1_000, 10_000] {
            let directory = tempDir()
            defer { try? FileManager.default.removeItem(at: directory) }

            // Seed a large file directly on disk.
            var seed: [String: MetadataDiskCache.Entry] = [:]
            let future = Date().addingTimeInterval(100_000)
            for index in 0..<count {
                seed["key-\(index)"] = MetadataDiskCache.Entry(url: "https://example.com/\(index).jpg", expires: future)
            }
            let seedData = try JSONEncoder().encode(seed)
            try seedData.write(to: directory.appendingPathComponent("plozz-metadata-cache-v3.json"))

            // Reader with a tiny budget: loading an oversized file triggers exactly
            // one prune, whose whole-map encodes must stay bounded (<= 3).
            let coding = CountingCoding()
            let reader = MetadataDiskCache(directory: directory, maxBytes: 3_000, fileIO: PassthroughFileIO(), coding: coding)
            _ = await reader.cached("key-0")

            XCTAssertLessThanOrEqual(
                coding.encodeCount, 3,
                "whole-map encodes must stay bounded (<=3) for \(count) entries, got \(coding.encodeCount)"
            )
            XCTAssertLessThanOrEqual(cacheFileSize(in: directory), 3_000, "reader must prune to its budget for \(count) entries")
        }
    }
}

/// Minimal real-filesystem FileIO used where a test needs default behavior but a
/// distinct instance from the production singleton.
private struct PassthroughFileIO: MetadataDiskCache.FileIO {
    func removeSupersededCaches(in directory: URL, currentFileName: String, filePrefix: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent != currentFileName
            && file.lastPathComponent.hasPrefix(filePrefix)
            && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }
    func read(from url: URL) -> Data? { try? Data(contentsOf: url) }
    func write(_ data: Data, to url: URL) { try? data.write(to: url, options: .atomic) }
}
