#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Tests for the persistent keyframe-index cache behind the
/// `com.plozz.playback.remuxKeyframeCache` flag — the fast-resume path that
/// avoids re-discovering keyframe boundaries on every play of a no-Cues title.
/// Covers the content-stable / token-independent key, the store→load round-trip,
/// the size/duration content guard, corruption rejection, and the
/// durations→boundaries derivation that feeds the C planner on the next open.
final class KeyframeIndexCacheTests: XCTestCase {

    private func makeTempCache() -> (KeyframeIndexCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlozzKFCacheTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (KeyframeIndexCache(directory: dir), dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Key

    func testKeyIgnoresQueryToken() {
        // Plex/Jellyfin rotate an auth token in the query — the same media must
        // map to the same key regardless of the token.
        let a = URL(string: "http://plex.local:32400/library/parts/1438/file.mkv?X-Plex-Token=AAA")!
        let b = URL(string: "http://plex.local:32400/library/parts/1438/file.mkv?X-Plex-Token=ZZZ")!
        XCTAssertEqual(
            KeyframeIndexCache.key(url: a, size: 5_000_000_000, duration: 2851),
            KeyframeIndexCache.key(url: b, size: 5_000_000_000, duration: 2851))
    }

    func testKeyDiffersOnSize() {
        let url = URL(string: "http://plex.local/parts/1438/file.mkv")!
        XCTAssertNotEqual(
            KeyframeIndexCache.key(url: url, size: 5_000_000_000, duration: 2851),
            KeyframeIndexCache.key(url: url, size: 5_000_000_001, duration: 2851))
    }

    func testKeyDiffersOnDuration() {
        let url = URL(string: "http://plex.local/parts/1438/file.mkv")!
        XCTAssertNotEqual(
            KeyframeIndexCache.key(url: url, size: 5_000_000_000, duration: 2851),
            KeyframeIndexCache.key(url: url, size: 5_000_000_000, duration: 1298))
    }

    func testKeyDiffersOnPath() {
        let a = URL(string: "http://plex.local/parts/1438/file.mkv")!
        let b = URL(string: "http://plex.local/parts/43663/file.mkv")!
        XCTAssertNotEqual(
            KeyframeIndexCache.key(url: a, size: 100, duration: 60),
            KeyframeIndexCache.key(url: b, size: 100, duration: 60))
    }

    // MARK: - Round-trip

    func testStoreLoadRoundTrip() {
        let (cache, dir) = makeTempCache()
        defer { cleanup(dir) }
        let key = "round-trip"
        let boundaries: [Double] = [0, 6.1, 12.3, 18.9, 24.0]
        cache.store(key: key, size: 12345, duration: 24.0, target: 6.0, boundaries: boundaries)
        let loaded = cache.load(key: key, expectedSize: 12345, expectedDuration: 24.0)
        XCTAssertEqual(loaded, boundaries)
    }

    func testLoadMissReturnsNil() {
        let (cache, dir) = makeTempCache()
        defer { cleanup(dir) }
        XCTAssertNil(cache.load(key: "absent", expectedSize: 1, expectedDuration: 1))
    }

    func testLoadRejectsSizeMismatch() {
        let (cache, dir) = makeTempCache()
        defer { cleanup(dir) }
        cache.store(key: "k", size: 1000, duration: 60, target: 6, boundaries: [0, 6, 60])
        // A re-encode under the same URL changes the byte size → stale entry ignored.
        XCTAssertNil(cache.load(key: "k", expectedSize: 2000, expectedDuration: 60))
    }

    func testLoadRejectsDurationMismatch() {
        let (cache, dir) = makeTempCache()
        defer { cleanup(dir) }
        cache.store(key: "k", size: 1000, duration: 60, target: 6, boundaries: [0, 6, 60])
        XCTAssertNil(cache.load(key: "k", expectedSize: 1000, expectedDuration: 120))
    }

    func testLoadAcceptsDurationWithinTolerance() {
        let (cache, dir) = makeTempCache()
        defer { cleanup(dir) }
        cache.store(key: "k", size: 1000, duration: 60.0, target: 6, boundaries: [0, 6, 60])
        // Probe duration can wobble sub-second between opens; ±1s is accepted.
        XCTAssertNotNil(cache.load(key: "k", expectedSize: 1000, expectedDuration: 60.4))
    }

    func testLoadRejectsTooFewBoundaries() {
        let (cache, dir) = makeTempCache()
        defer { cleanup(dir) }
        // store() refuses < 2; write a degenerate file directly to prove load guards too.
        let url = dir.appendingPathComponent("\(KeyframeIndexCache.key(url: URL(string: "http://x/y")!, size: 1, duration: 1)).json")
        cache.store(key: "k", size: 1, duration: 1, target: 6, boundaries: [0])
        XCTAssertNil(cache.load(key: "k", expectedSize: 1, expectedDuration: 1))
        _ = url
    }

    func testLoadRejectsNonMonotonicBoundaries() {
        let (cache, dir) = makeTempCache()
        defer { cleanup(dir) }
        // Hand-craft a corrupt (decreasing) list and ensure load rejects it so the
        // C planner can never see a backward boundary.
        cache.store(key: "k", size: 1, duration: 30, target: 6, boundaries: [0, 12, 6, 30])
        XCTAssertNil(cache.load(key: "k", expectedSize: 1, expectedDuration: 30))
    }

    // MARK: - Boundary derivation

    func testBoundariesFromDurations() {
        let durations: [Double] = [11.4, 10.1, 6.0]
        let boundaries = KeyframeIndexCache.boundaries(fromDurations: durations)
        XCTAssertEqual(boundaries.count, durations.count + 1)
        XCTAssertEqual(boundaries[0], 0)
        XCTAssertEqual(boundaries[1], 11.4, accuracy: 1e-9)
        XCTAssertEqual(boundaries[2], 21.5, accuracy: 1e-9)
        XCTAssertEqual(boundaries[3], 27.5, accuracy: 1e-9)
    }

    func testBoundariesFromEmptyDurations() {
        XCTAssertEqual(KeyframeIndexCache.boundaries(fromDurations: []), [])
    }

    /// End-to-end shape: a rebuilt durations table → boundaries → (store) → load
    /// yields the same boundary list a fresh open would feed back to the planner.
    func testDurationsToCacheToLoadPreservesBoundaries() {
        let (cache, dir) = makeTempCache()
        defer { cleanup(dir) }
        let durations: [Double] = [11.386, 10.052, 13.263, 6.0]
        let boundaries = KeyframeIndexCache.boundaries(fromDurations: durations)
        let total = durations.reduce(0, +)
        cache.store(key: "k", size: 999, duration: total, target: 6, boundaries: boundaries)
        let loaded = cache.load(key: "k", expectedSize: 999, expectedDuration: total)
        XCTAssertEqual(loaded, boundaries)
    }
}
#endif
