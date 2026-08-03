import XCTest
@testable import FeatureHomeCore

/// The gauge's two sources — the dwell timer and a trailer's own clock — are
/// where every visible bug in this bar came from.
final class HeroGaugeStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func resolve(
        autoAdvance: Bool = true,
        at offset: TimeInterval,
        dwell: TimeInterval = 10,
        isTransitioning: Bool = false,
        trailerElapsed: Double? = nil,
        trailerDuration: Double? = nil
    ) -> HeroGaugeState {
        HeroGaugeState.resolve(
            autoAdvance: autoAdvance,
            dwellStart: start,
            dwellDuration: dwell,
            now: start.addingTimeInterval(offset),
            isTransitioning: isTransitioning,
            trailerElapsed: trailerElapsed,
            trailerDuration: trailerDuration
        )
    }

    func testDwellRampsFromEmptyToFull() {
        XCTAssertEqual(resolve(at: 0).fraction, 0, accuracy: 0.001)
        XCTAssertEqual(resolve(at: 5).fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(resolve(at: 5).remaining ?? 0, 5, accuracy: 0.001)
    }

    /// The bar was full for the whole of the incoming slide. Mid-transition the
    /// view already points at the new slide while `dwellStart` still belongs to
    /// the old one, so the elapsed time read as a finished dwell.
    func testAnIncomingSlideStartsEmptyRatherThanFull() {
        // Stale dwell: far past the old slide's duration.
        let state = resolve(at: 30)
        XCTAssertEqual(state.fraction, 0, "the incoming bar must start empty")
        XCTAssertEqual(state.remaining ?? 0, 10, accuracy: 0.001)

        // And explicitly during a transition, even if the clocks look sane.
        let transitioning = resolve(at: 4, isTransitioning: true)
        XCTAssertEqual(transitioning.fraction, 0)
    }

    /// The bar emptied and restarted when a trailer's clock arrived. Until the
    /// trailer reports a usable duration it says nothing about progress, so the
    /// dwell must keep driving the bar.
    func testATrailerWithNoUsableClockDoesNotResetTheBar() {
        for (elapsed, duration) in [
            (0.0, 0.0),
            (Double.nan, 30.0),
            (-1.0, 30.0),
            (5.0, 0.0)
        ] {
            let state = resolve(at: 4, trailerElapsed: elapsed, trailerDuration: duration)
            XCTAssertEqual(
                state.fraction,
                0.4,
                accuracy: 0.001,
                "elapsed=\(elapsed) duration=\(duration) should fall back to the dwell"
            )
            XCTAssertNotNil(state.remaining, "the bar must keep moving")
        }
    }

    func testAPlayingTrailerDrivesTheBar() {
        let state = resolve(at: 4, trailerElapsed: 30, trailerDuration: 120)
        XCTAssertEqual(state.fraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(state.remaining ?? 0, 90, accuracy: 0.001)
    }

    /// With auto-advance off there is no countdown, so the pill is solid and
    /// nothing animates.
    func testAutoAdvanceOffHoldsAFullPillWithNoRamp() {
        let state = resolve(autoAdvance: false, at: 3)
        XCTAssertEqual(state.fraction, 1)
        XCTAssertNil(state.remaining)
    }

    func testFractionNeverLeavesItsRange() {
        XCTAssertEqual(resolve(at: -5).fraction, 0)
        XCTAssertEqual(resolve(at: 4, trailerElapsed: 999, trailerDuration: 10).fraction, 1)
    }
}
