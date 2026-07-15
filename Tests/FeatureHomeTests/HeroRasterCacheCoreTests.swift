import XCTest
@testable import FeatureHome

/// Locks down the pure hero raster cache state machine: HIT/MISS, staleness,
/// generation invalidation, window-protected byte-budget eviction, and the
/// rapid-paging / reversal access patterns the maintainer cares about most.
final class HeroRasterCacheCoreTests: XCTestCase {
    private func fingerprint(_ id: String, logoURL: String? = "logo", width: Int = 600) -> HeroForegroundFingerprint {
        HeroForegroundFingerprint(
            itemID: id,
            title: "T-\(id)",
            overview: "O-\(id)",
            metadata: "2024 · 1h",
            ratingBadgeID: nil,
            logoURLString: logoURL,
            isDarkMode: true,
            contentWidth: width
        )
    }

    // MARK: - Hit / miss / staleness

    func testMissWhenEmptyThenHitAfterStore() {
        var cache = HeroRasterCacheCore(byteBudget: 10_000)
        let fp = fingerprint("a")
        XCTAssertFalse(cache.lookup(itemID: "a", fingerprint: fp))
        cache.store(itemID: "a", fingerprint: fp, byteCost: 100)
        XCTAssertTrue(cache.lookup(itemID: "a", fingerprint: fp))
        XCTAssertEqual(cache.hits, 1)
        XCTAssertEqual(cache.misses, 1)
    }

    func testStaleFingerprintIsAMiss() {
        var cache = HeroRasterCacheCore(byteBudget: 10_000)
        cache.store(itemID: "a", fingerprint: fingerprint("a", width: 500), byteCost: 100)
        // Width changed (pills re-measured) → fingerprint changed → stale → MISS.
        XCTAssertFalse(cache.lookup(itemID: "a", fingerprint: fingerprint("a", width: 900)))
        XCTAssertTrue(cache.needsPreparation(itemID: "a", fingerprint: fingerprint("a", width: 900)))
    }

    func testContainsHasNoStatsOrLRUSideEffects() {
        var cache = HeroRasterCacheCore(byteBudget: 10_000)
        let fp = fingerprint("a")
        cache.store(itemID: "a", fingerprint: fp, byteCost: 100)
        XCTAssertTrue(cache.contains(itemID: "a", fingerprint: fp))
        XCTAssertEqual(cache.hits, 0, "contains must not record a HIT")
        XCTAssertEqual(cache.misses, 0)
    }

    // MARK: - Generation invalidation

    func testInvalidateAllBumpsGenerationAndDropsEverything() {
        var cache = HeroRasterCacheCore(byteBudget: 10_000)
        cache.store(itemID: "a", fingerprint: fingerprint("a"), byteCost: 100)
        cache.store(itemID: "b", fingerprint: fingerprint("b"), byteCost: 100)
        let gen0 = cache.generation
        let dropped = cache.invalidateAll(reason: "set-swap")
        XCTAssertEqual(Set(dropped), ["a", "b"])
        XCTAssertEqual(cache.generation, gen0 + 1)
        XCTAssertEqual(cache.totalBytes, 0)
        XCTAssertFalse(cache.lookup(itemID: "a", fingerprint: fingerprint("a")))
    }

    // MARK: - Byte-budget eviction protecting the window

    func testEvictionDropsColdestOutsideWindow() {
        var cache = HeroRasterCacheCore(byteBudget: 250)
        // Store a, b, c each 100 bytes (budget 250). Touch a so b is coldest.
        cache.store(itemID: "a", fingerprint: fingerprint("a"), byteCost: 100)
        cache.store(itemID: "b", fingerprint: fingerprint("b"), byteCost: 100)
        _ = cache.lookup(itemID: "a", fingerprint: fingerprint("a")) // a most-recent
        let evicted = cache.store(
            itemID: "c",
            fingerprint: fingerprint("c"),
            byteCost: 100,
            windowItemIDs: ["a", "c"] // protect the in-window slides
        )
        XCTAssertEqual(evicted, ["b"], "coldest, unprotected slide is evicted")
        XCTAssertLessThanOrEqual(cache.totalBytes, 250)
        XCTAssertEqual(cache.storedItemIDs, ["a", "c"])
    }

    func testProtectedWindowIsNeverEvictedEvenOverBudget() {
        var cache = HeroRasterCacheCore(byteBudget: 150)
        cache.store(itemID: "a", fingerprint: fingerprint("a"), byteCost: 100, windowItemIDs: ["a", "b"])
        // Storing b pushes to 200 > 150, but both are protected → nothing evicted.
        let evicted = cache.store(itemID: "b", fingerprint: fingerprint("b"), byteCost: 100, windowItemIDs: ["a", "b"])
        XCTAssertEqual(evicted, [])
        XCTAssertEqual(cache.storedItemIDs, ["a", "b"])
        XCTAssertEqual(cache.totalBytes, 200)
    }

    // MARK: - Rapid paging / reversal patterns

    func testRapidForwardThenReversalStaysConsistent() {
        var cache = HeroRasterCacheCore(byteBudget: 500) // 5 slots @100
        let ids = ["s0", "s1", "s2", "s3", "s4"]
        for id in ids { cache.store(itemID: id, fingerprint: fingerprint(id), byteCost: 100, windowItemIDs: ids) }
        // Rapid forward hits.
        for id in ["s1", "s2", "s3"] {
            XCTAssertTrue(cache.lookup(itemID: id, fingerprint: fingerprint(id)), "forward hit \(id)")
        }
        // Mid-transition reversal — backward hits still resolve.
        for id in ["s2", "s1", "s0"] {
            XCTAssertTrue(cache.lookup(itemID: id, fingerprint: fingerprint(id)), "reversal hit \(id)")
        }
    }

    func testPagingOutrunsPreparationRecordsMiss() {
        var cache = HeroRasterCacheCore(byteBudget: 10_000)
        cache.store(itemID: "s0", fingerprint: fingerprint("s0"), byteCost: 100)
        // User pages to s7 before its snapshot exists → MISS (caller falls back live).
        XCTAssertFalse(cache.lookup(itemID: "s7", fingerprint: fingerprint("s7")))
        XCTAssertEqual(cache.misses, 1)
    }

    func testDropReleasesBytes() {
        var cache = HeroRasterCacheCore(byteBudget: 10_000)
        cache.store(itemID: "a", fingerprint: fingerprint("a"), byteCost: 100)
        XCTAssertTrue(cache.drop(itemID: "a"))
        XCTAssertEqual(cache.totalBytes, 0)
        XCTAssertFalse(cache.drop(itemID: "a"), "second drop is a no-op")
    }

    func testReStoreSameIDReplacesBytesNotAccumulates() {
        var cache = HeroRasterCacheCore(byteBudget: 10_000)
        cache.store(itemID: "a", fingerprint: fingerprint("a", width: 500), byteCost: 100)
        cache.store(itemID: "a", fingerprint: fingerprint("a", width: 900), byteCost: 140)
        XCTAssertEqual(cache.totalBytes, 140, "replacement overwrites, not accumulates")
        XCTAssertEqual(cache.count, 1)
    }
}
