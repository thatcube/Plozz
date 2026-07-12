import XCTest
@testable import CoreUI

final class HeroLogoPresentationPolicyTests: XCTestCase {
    func testWhenReadyAlwaysAdoptsResolvedLogo() {
        let policy = HeroLogoPresentationPolicy.whenReady

        XCTAssertTrue(policy.shouldAdopt(elapsed: 30))
        XCTAssertTrue(policy.animatesResolvedLogo)
    }

    func testOnArrivalAdoptsOnlyInsideArrivalWindow() {
        let policy = HeroLogoPresentationPolicy.onArrival(maximumWait: 0.2)

        XCTAssertTrue(policy.shouldAdopt(elapsed: 0.2))
        XCTAssertFalse(policy.shouldAdopt(elapsed: 0.201))
        XCTAssertFalse(policy.animatesResolvedLogo)
    }

    func testOnArrivalTreatsNegativeWindowAsImmediateOnly() {
        let policy = HeroLogoPresentationPolicy.onArrival(maximumWait: -1)

        XCTAssertTrue(policy.shouldAdopt(elapsed: 0))
        XCTAssertFalse(policy.shouldAdopt(elapsed: 0.001))
    }
}
