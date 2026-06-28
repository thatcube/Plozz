#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Tests for the OPTIONAL ETag / Last-Modified validator guard added to
/// `KeyframeIndexCache` for Track C — the second invalidation layer that catches a
/// same-size, same-duration re-encode the size+duration guard alone can't see.
/// Backward compatibility (nil validators behaving exactly as before) is asserted
/// so the existing fast path against ETag-less origins is unchanged.
final class KeyframeIndexCacheETagTests: XCTestCase {

    private func makeTempCache() -> (KeyframeIndexCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlozzKFETagTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (KeyframeIndexCache(directory: dir), dir)
    }

    private func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    func testMatchingETagLoads() {
        let (cache, dir) = makeTempCache(); defer { cleanup(dir) }
        cache.store(key: "k", size: 1000, duration: 60, target: 6,
                    times: [0, 6, 60], etag: "\"abc\"")
        XCTAssertNotNil(cache.load(key: "k", expectedSize: 1000, expectedDuration: 60,
                                   expectedETag: "\"abc\""))
    }

    func testMismatchedETagIsMiss() {
        let (cache, dir) = makeTempCache(); defer { cleanup(dir) }
        // Same size + duration, but a re-encode changed the ETag → stale entry.
        cache.store(key: "k", size: 1000, duration: 60, target: 6,
                    times: [0, 6, 60], etag: "\"abc\"")
        XCTAssertNil(cache.load(key: "k", expectedSize: 1000, expectedDuration: 60,
                                expectedETag: "\"xyz\""))
    }

    func testNilExpectedETagFallsBackToSizeDuration() {
        let (cache, dir) = makeTempCache(); defer { cleanup(dir) }
        // Entry has an ETag but the caller (HEAD unsupported) supplies none → the
        // size+duration guard still validates, so the fast path keeps working.
        cache.store(key: "k", size: 1000, duration: 60, target: 6,
                    times: [0, 6, 60], etag: "\"abc\"")
        XCTAssertNotNil(cache.load(key: "k", expectedSize: 1000, expectedDuration: 60))
    }

    func testStoredWithoutETagIgnoresExpectedETag() {
        let (cache, dir) = makeTempCache(); defer { cleanup(dir) }
        // Legacy / ETag-less entry: an expected ETag can't invalidate it (nothing to
        // compare), so size+duration remains the guard.
        cache.store(key: "k", size: 1000, duration: 60, target: 6, times: [0, 6, 60])
        XCTAssertNotNil(cache.load(key: "k", expectedSize: 1000, expectedDuration: 60,
                                   expectedETag: "\"abc\""))
    }

    func testMismatchedLastModifiedIsMissWhenNoETag() {
        let (cache, dir) = makeTempCache(); defer { cleanup(dir) }
        cache.store(key: "k", size: 1000, duration: 60, target: 6,
                    times: [0, 6, 60], lastModified: "Wed, 01 Jan 2025 00:00:00 GMT")
        XCTAssertNil(cache.load(key: "k", expectedSize: 1000, expectedDuration: 60,
                                expectedLastModified: "Thu, 02 Jan 2025 00:00:00 GMT"))
    }

    func testMatchingLastModifiedLoads() {
        let (cache, dir) = makeTempCache(); defer { cleanup(dir) }
        let lm = "Wed, 01 Jan 2025 00:00:00 GMT"
        cache.store(key: "k", size: 1000, duration: 60, target: 6,
                    times: [0, 6, 60], lastModified: lm)
        XCTAssertNotNil(cache.load(key: "k", expectedSize: 1000, expectedDuration: 60,
                                   expectedLastModified: lm))
    }
}
#endif
