import XCTest
@testable import FeatureHomeCore

/// The fill only travels `activeWidth - dotSize` points across a whole dwell, so
/// ticking it at a fixed 30 Hz redrew an identical result most frames — measured
/// as a steady 7.2% CPU on an iPhone doing nothing else.
final class HeroPagingIndicatorRateTests: XCTestCase {
    private typealias Metrics = HeroPagingIndicatorMetrics

    func testUpdateRateIsProportionalToWhatTheFillCanActuallyShow() {
        let travel = Double(Metrics.activeWidth - Metrics.dotSize)
        for dwell in [8.0, 10.0, 15.0] {
            let interval = Metrics.fillUpdateInterval(dwellSeconds: dwell)
            let updates = dwell / interval
            XCTAssertLessThanOrEqual(
                updates,
                travel * 2 + 1,
                "\(dwell)s dwell should not redraw far past one update per point"
            )
            XCTAssertGreaterThanOrEqual(
                updates,
                travel,
                "\(dwell)s dwell still needs enough updates to look continuous"
            )
        }
    }

    func testARealisticDwellCostsFarFewerUpdatesThanThirtyHertz() {
        let interval = Metrics.fillUpdateInterval(dwellSeconds: 10)
        let updates = 10 / interval
        XCTAssertLessThan(
            updates,
            10 * 30 / 4,
            "should be at least a 4x reduction against the old fixed 30 Hz tick"
        )
    }

    /// An unusual dwell must neither spin nor visibly step.
    func testIntervalStaysWithinSaneBounds() {
        for dwell in [0.0, 0.5, 1.0, 60.0, 3600.0] {
            let interval = Metrics.fillUpdateInterval(dwellSeconds: dwell)
            XCTAssertGreaterThanOrEqual(interval, 1.0 / 15, "\(dwell)s spun too fast")
            XCTAssertLessThanOrEqual(interval, 1.0 / 2, "\(dwell)s would step visibly")
        }
    }
}
