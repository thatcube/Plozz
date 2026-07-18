import XCTest
@testable import ProviderShare

final class ShareBacklogFairnessPolicyTests: XCTestCase {
    private func candidate(
        _ key: String,
        preferred: Bool,
        age: Duration,
        now: ContinuousClock.Instant
    ) -> ShareBacklogFairnessPolicy.Candidate {
        // enqueuedAt = now - age (older entries sort first).
        .init(accountKey: key, isPreferred: preferred, enqueuedAt: now.advanced(by: .zero - age))
    }

    func testPrefersPreferredFirstBelowBurstAndBelowAge() {
        let policy = ShareBacklogFairnessPolicy(preferredBurst: 4, agePromotion: .seconds(30))
        let now = ContinuousClock().now
        let order = policy.order(
            candidates: [
                candidate("n", preferred: false, age: .zero, now: now),
                candidate("p", preferred: true, age: .zero, now: now),
            ],
            consecutivePreferredAdmissions: 0,
            now: now
        )
        XCTAssertEqual(order, ["p", "n"])
    }

    func testSurfacesOneNonPreferredWhenBurstReached() {
        let policy = ShareBacklogFairnessPolicy(preferredBurst: 2, agePromotion: .seconds(30))
        let now = ContinuousClock().now
        let order = policy.order(
            candidates: [
                candidate("p", preferred: true, age: .zero, now: now),
                candidate("n", preferred: false, age: .zero, now: now),
            ],
            consecutivePreferredAdmissions: 2,
            now: now
        )
        XCTAssertEqual(order.first, "n", "at the burst limit one non-preferred account leads")
        XCTAssertEqual(Set(order), ["n", "p"])
    }

    func testBelowBurstKeepsPreferredFirstEvenWithNonPreferredPresent() {
        let policy = ShareBacklogFairnessPolicy(preferredBurst: 4, agePromotion: .seconds(30))
        let now = ContinuousClock().now
        let order = policy.order(
            candidates: [
                candidate("p", preferred: true, age: .zero, now: now),
                candidate("n", preferred: false, age: .zero, now: now),
            ],
            consecutivePreferredAdmissions: 3,
            now: now
        )
        XCTAssertEqual(order, ["p", "n"])
    }

    func testAgedNonPreferredLeadsRegardlessOfBurstCounter() {
        let policy = ShareBacklogFairnessPolicy(preferredBurst: 100, agePromotion: .seconds(30))
        let now = ContinuousClock().now
        let order = policy.order(
            candidates: [
                candidate("p", preferred: true, age: .zero, now: now),
                candidate("n", preferred: false, age: .seconds(31), now: now),
            ],
            consecutivePreferredAdmissions: 0,
            now: now
        )
        XCTAssertEqual(order.first, "n", "an aged non-preferred account is promoted even below burst")
    }

    func testAgedNonPreferredOrderedOldestFirst() {
        let policy = ShareBacklogFairnessPolicy(preferredBurst: 100, agePromotion: .seconds(30))
        let now = ContinuousClock().now
        let order = policy.order(
            candidates: [
                candidate("young", preferred: false, age: .seconds(31), now: now),
                candidate("old", preferred: false, age: .seconds(90), now: now),
                candidate("p", preferred: true, age: .zero, now: now),
            ],
            consecutivePreferredAdmissions: 0,
            now: now
        )
        XCTAssertEqual(Array(order.prefix(2)), ["old", "young"], "oldest aged account leads")
        XCTAssertEqual(order.last, "p")
    }

    func testPreservesFifoWithinPreferredClass() {
        let policy = ShareBacklogFairnessPolicy(preferredBurst: 4, agePromotion: .seconds(30))
        let now = ContinuousClock().now
        let order = policy.order(
            candidates: [
                candidate("p1", preferred: true, age: .zero, now: now),
                candidate("p2", preferred: true, age: .zero, now: now),
                candidate("p3", preferred: true, age: .zero, now: now),
            ],
            consecutivePreferredAdmissions: 0,
            now: now
        )
        XCTAssertEqual(order, ["p1", "p2", "p3"])
    }

    func testBurstWithoutNonPreferredKeepsPreferredOrder() {
        let policy = ShareBacklogFairnessPolicy(preferredBurst: 1, agePromotion: .seconds(30))
        let now = ContinuousClock().now
        let order = policy.order(
            candidates: [candidate("p", preferred: true, age: .zero, now: now)],
            consecutivePreferredAdmissions: 5,
            now: now
        )
        XCTAssertEqual(order, ["p"], "no non-preferred account to surface leaves preferred order intact")
    }

    func testBurstFloorIsAtLeastOne() {
        let policy = ShareBacklogFairnessPolicy(preferredBurst: 0, agePromotion: .seconds(30))
        XCTAssertEqual(policy.preferredBurst, 1)
    }
}
