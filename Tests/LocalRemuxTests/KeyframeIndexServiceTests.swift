#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Tests for `KeyframeIndexService` — Track C's replay fast-path glue: the
/// parser-agnostic `persist` producer entry point and the `CachedProvider`
/// conformance that hands a cache HIT to the shared `KeyframeProvider` seam as a
/// `KeyframeTable`. Validates the offset-free (`byteOffsets == nil`) persistence
/// invariant and the size/duration content guard. Pure disk + value logic; no
/// network, no scan, no second parser.
final class KeyframeIndexServiceTests: XCTestCase {

    private func makeTempCache() -> (KeyframeIndexCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlozzKFServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (KeyframeIndexCache(directory: dir), dir)
    }

    private func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    private let url = URL(string: "http://jelly.local/Items/abc/file.mkv?api_key=ROTATING")!

    func testPersistThenProviderRoundTripsAsKeyframeTable() {
        let (cache, dir) = makeTempCache(); defer { cleanup(dir) }
        let size: Int64 = 21_000_000_000
        let duration = 8520.0
        let table = KeyframeTable(duration: duration, times: [0, 6.04, 12.1, 18.0])

        XCTAssertTrue(KeyframeIndexService.persist(
            table, url: url, size: size, duration: duration, target: 6.0,
            validators: nil, cache: cache))

        let provider = KeyframeIndexService.CachedProvider(
            url: url, size: size, duration: duration, validators: nil, cache: cache)
        let loaded = provider.keyframeTable()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.times, table.times)
        XCTAssertEqual(loaded?.duration, duration)
        // Track C persistence is offset-free — offsets are re-derived at mux.
        XCTAssertNil(loaded?.byteOffsets)
        XCTAssertEqual(loaded?.isUsable, true)
    }

    func testProviderMissOnSizeMismatch() {
        let (cache, dir) = makeTempCache(); defer { cleanup(dir) }
        let duration = 8520.0
        let table = KeyframeTable(duration: duration, times: [0, 6, 12, 18])
        _ = KeyframeIndexService.persist(
            table, url: url, size: 21_000_000_000, duration: duration, target: 6.0,
            validators: nil, cache: cache)

        // A re-encode under the same URL changes the byte size → content guard miss.
        let provider = KeyframeIndexService.CachedProvider(
            url: url, size: 21_000_000_001, duration: duration, validators: nil, cache: cache)
        XCTAssertNil(provider.keyframeTable())
    }

    func testPersistRejectsUnusableTable() {
        let (cache, dir) = makeTempCache(); defer { cleanup(dir) }
        // Fewer than two keyframes is unusable by the planner → not persisted.
        let one = KeyframeTable(duration: 100, times: [0])
        XCTAssertFalse(KeyframeIndexService.persist(
            one, url: url, size: 5_000, duration: 100, target: 6.0,
            validators: nil, cache: cache))
        let provider = KeyframeIndexService.CachedProvider(
            url: url, size: 5_000, duration: 100, validators: nil, cache: cache)
        XCTAssertNil(provider.keyframeTable())
    }

    func testFreshTableDefaultsToOffsetFree() {
        // The seam carries an optional byteOffsets; Track C never populates it.
        let t = KeyframeTable(duration: 60, times: [0, 6, 12])
        XCTAssertNil(t.byteOffsets)
    }
}
#endif
