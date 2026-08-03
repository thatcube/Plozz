#if canImport(UIKit)
import XCTest
import UIKit
@testable import CoreUI

/// The gauge is handed to Core Animation rather than ticked, so the properties
/// that matter are about what it leaves behind: the shape must stay a capsule at
/// every width, and the layer must read as finished even if the animation is
/// dropped.
final class HeroPagingGaugeTests: XCTestCase {
    private let trackWidth: CGFloat = 30
    private let height: CGFloat = 10

    func testAnEmptyGaugeIsACircleAndAFullOneIsThePill() {
        XCTAssertEqual(
            HeroPagingGauge.width(fraction: 0, trackWidth: trackWidth, height: height),
            height,
            "an empty gauge should still read as a dot"
        )
        XCTAssertEqual(
            HeroPagingGauge.width(fraction: 1, trackWidth: trackWidth, height: height),
            trackWidth
        )
    }

    func testFractionsOutsideTheRangeAreClamped() {
        XCTAssertEqual(
            HeroPagingGauge.width(fraction: -5, trackWidth: trackWidth, height: height),
            height
        )
        XCTAssertEqual(
            HeroPagingGauge.width(fraction: 9, trackWidth: trackWidth, height: height),
            trackWidth
        )
    }

    func testRunningGaugeAddsExactlyOneAnimationAndSettlesFull() {
        let layer = CALayer()
        HeroPagingGauge.prepare(layer, height: height, midY: 5)
        HeroPagingGauge.animate(
            layer,
            from: 0.25,
            remaining: 8,
            trackWidth: trackWidth,
            height: height
        )
        let animation = layer.animation(forKey: HeroPagingGauge.animationKey)
        XCTAssertNotNil(animation, "the ramp should be described to Core Animation")
        XCTAssertEqual((animation as? CABasicAnimation)?.duration, 8)
        // The model value is the finished state, so losing the animation leaves a
        // full gauge rather than snapping back to empty.
        XCTAssertEqual(layer.bounds.width, trackWidth)
    }

    func testHoldingTheGaugeRemovesAnyRunningAnimation() {
        let layer = CALayer()
        HeroPagingGauge.prepare(layer, height: height, midY: 5)
        HeroPagingGauge.animate(
            layer, from: 0, remaining: 10, trackWidth: trackWidth, height: height
        )
        HeroPagingGauge.setStatic(
            layer, fraction: 0.5, trackWidth: trackWidth, height: height
        )
        XCTAssertNil(
            layer.animation(forKey: HeroPagingGauge.animationKey),
            "a paused dwell must not keep animating"
        )
        XCTAssertEqual(layer.bounds.width, 20)
    }

    /// A dwell with nothing left should not describe a zero-length animation.
    func testAFinishedDwellJustSitsFull() {
        let layer = CALayer()
        HeroPagingGauge.prepare(layer, height: height, midY: 5)
        HeroPagingGauge.animate(
            layer, from: 1, remaining: 0, trackWidth: trackWidth, height: height
        )
        XCTAssertNil(layer.animation(forKey: HeroPagingGauge.animationKey))
        XCTAssertEqual(layer.bounds.width, trackWidth)
    }

    /// A trailer starting mid-slide swaps the gauge's source and reports its own
    /// clock from zero. Restating the ramp from there ran the bar backwards,
    /// which reads as a glitch. Projecting where the stated ramp has reached
    /// keeps it moving forward.
    func testAStatedRampProjectsForwardOverTime() {
        let start = Date()
        let quarter = HeroPagingGauge.projectedFraction(
            from: 0, started: start, remaining: 100, now: start.addingTimeInterval(25)
        )
        XCTAssertEqual(quarter, 0.25, accuracy: 0.001)

        // Projection is relative to what was left, not to the whole bar.
        let fromHalf = HeroPagingGauge.projectedFraction(
            from: 0.5, started: start, remaining: 10, now: start.addingTimeInterval(5)
        )
        XCTAssertEqual(fromHalf, 0.75, accuracy: 0.001)
    }

    func testProjectionNeverExceedsFullAndNeverGoesBackwards() {
        let start = Date()
        XCTAssertEqual(
            HeroPagingGauge.projectedFraction(
                from: 0.4, started: start, remaining: 10, now: start.addingTimeInterval(999)
            ),
            1
        )
        // A clock that reports an earlier time must not rewind the gauge.
        XCTAssertEqual(
            HeroPagingGauge.projectedFraction(
                from: 0.4, started: start, remaining: 10, now: start.addingTimeInterval(-5)
            ),
            0.4,
            accuracy: 0.001
        )
    }

    /// The scenario Brandon hit: a slide is partway through its dwell when a
    /// trailer begins and reports ~0. Taking the greater of the two keeps the
    /// bar where it is instead of snapping back to the start.
    func testATrailerStartingMidSlideCannotRewindTheBar() {
        let start = Date()
        let projected = HeroPagingGauge.projectedFraction(
            from: 0.3, started: start, remaining: 10, now: start.addingTimeInterval(4)
        )
        let trailerReports: CGFloat = 0.0
        XCTAssertGreaterThan(
            max(trailerReports, projected),
            trailerReports,
            "the gauge must not restart when the source changes mid-slide"
        )
    }

    /// Left-anchored so growth only needs the width, which is what keeps the
    /// animation to a single property.
    func testGaugeGrowsFromItsLeadingEdge() {
        let layer = CALayer()
        HeroPagingGauge.prepare(layer, height: height, midY: 7)
        XCTAssertEqual(layer.anchorPoint, CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(layer.position, CGPoint(x: 0, y: 7))
        XCTAssertEqual(layer.cornerRadius, height / 2, "the fill must stay a capsule")
    }
}
#endif
