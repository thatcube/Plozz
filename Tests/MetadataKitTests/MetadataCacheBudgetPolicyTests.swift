import XCTest
@testable import MetadataKit

final class MetadataCacheBudgetPolicyTests: XCTestCase {
    private func sized(_ key: String, expiresIn seconds: TimeInterval, size: Int) -> MetadataCacheBudgetPolicy.SizedEntry {
        MetadataCacheBudgetPolicy.SizedEntry(key: key, expires: Date().addingTimeInterval(seconds), estimatedSize: size)
    }

    func testWithinBudgetEvictsNothing() {
        let policy = MetadataCacheBudgetPolicy()
        let entries = [sized("a", expiresIn: 10, size: 100), sized("b", expiresIn: 20, size: 100)]
        XCTAssertEqual(policy.evictionKeys(entries, maxBytes: 10_000), [])
    }

    func testEvictsOldestExpiringFirstUntilWithinBudget() {
        let policy = MetadataCacheBudgetPolicy()
        // Sizes: 200 each + 2 overhead = 602 total; budget 300 => must drop the two
        // oldest-expiring to reach <= 300 (leaving one 200 + overhead = 202).
        let entries = [
            sized("newest", expiresIn: 300, size: 200),
            sized("middle", expiresIn: 200, size: 200),
            sized("oldest", expiresIn: 100, size: 200),
        ]
        let evicted = policy.evictionKeys(entries, maxBytes: 300)
        XCTAssertEqual(evicted, ["oldest", "middle"], "oldest-expiring entries are evicted first")
    }

    func testDeterministicTieBreakByKey() {
        let policy = MetadataCacheBudgetPolicy()
        // Equal expiry: tie broken by key ascending, so "aaa" evicts before "bbb".
        // Share ONE expiry instant so the entries are a genuine tie — reading
        // `Date()` per entry would make "bbb" (created first) expire marginally
        // earlier and evict on recency, not the key tie-break under test.
        let expires = Date().addingTimeInterval(100)
        let entries = [
            MetadataCacheBudgetPolicy.SizedEntry(key: "bbb", expires: expires, estimatedSize: 200),
            MetadataCacheBudgetPolicy.SizedEntry(key: "aaa", expires: expires, estimatedSize: 200),
        ]
        let evicted = policy.evictionKeys(entries, maxBytes: 250)
        XCTAssertEqual(evicted, ["aaa"], "ties broken deterministically by key")
    }

    func testTinyBudgetCanEvictEverything() {
        let policy = MetadataCacheBudgetPolicy()
        let entries = [sized("a", expiresIn: 10, size: 100), sized("b", expiresIn: 20, size: 100)]
        XCTAssertEqual(Set(policy.evictionKeys(entries, maxBytes: 0)), ["a", "b"])
    }

    func testEmptyInputEvictsNothing() {
        let policy = MetadataCacheBudgetPolicy()
        XCTAssertEqual(policy.evictionKeys([], maxBytes: 0), [])
    }
}
