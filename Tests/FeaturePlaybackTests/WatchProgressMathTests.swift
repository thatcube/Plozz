import XCTest
@testable import FeaturePlayback

/// Tests the pure duration/watched-percentage arithmetic extracted from
/// `PlayerViewModel`. These pin the rules that keep resume points and Trakt
/// scrobbles honest: which duration source wins, and how a captured stop
/// position maps to a 0...100 percentage.
final class WatchProgressMathTests: XCTestCase {
    // MARK: knownDuration

    func testKnownDurationPrefersEngineWhenValid() {
        let d = WatchProgressMath.knownDuration(
            engineDuration: 1200, controlsDuration: 1100, itemRuntime: 1000)
        XCTAssertEqual(d, 1200)
    }

    func testKnownDurationFallsBackToControlsWhenEngineUnknown() {
        let d = WatchProgressMath.knownDuration(
            engineDuration: 0, controlsDuration: 1100, itemRuntime: 1000)
        XCTAssertEqual(d, 1100)
    }

    func testKnownDurationFallsBackToRuntimeWhenEngineAndControlsUnknown() {
        let d = WatchProgressMath.knownDuration(
            engineDuration: 0, controlsDuration: 0, itemRuntime: 1000)
        XCTAssertEqual(d, 1000)
    }

    func testKnownDurationIgnoresNonFiniteEngineDuration() {
        let d = WatchProgressMath.knownDuration(
            engineDuration: .infinity, controlsDuration: 900, itemRuntime: nil)
        XCTAssertEqual(d, 900)
    }

    func testKnownDurationNilWhenNothingKnown() {
        XCTAssertNil(WatchProgressMath.knownDuration(
            engineDuration: 0, controlsDuration: 0, itemRuntime: nil))
        XCTAssertNil(WatchProgressMath.knownDuration(
            engineDuration: 0, controlsDuration: 0, itemRuntime: 0))
    }

    // MARK: watchedPercent

    func testWatchedPercentMidPlayback() {
        let p = WatchProgressMath.watchedPercent(
            position: 600, engineDuration: 1200, itemRuntime: nil)
        XCTAssertEqual(p, 50, accuracy: 0.0001)
    }

    func testWatchedPercentPrefersEngineDurationOverRuntime() {
        // Engine says the real container is 1000s even though catalog runtime is
        // 2000s; the percentage must use the engine duration.
        let p = WatchProgressMath.watchedPercent(
            position: 500, engineDuration: 1000, itemRuntime: 2000)
        XCTAssertEqual(p, 50, accuracy: 0.0001)
    }

    func testWatchedPercentFallsBackToRuntimeWhenEngineUnknown() {
        let p = WatchProgressMath.watchedPercent(
            position: 500, engineDuration: 0, itemRuntime: 2000)
        XCTAssertEqual(p, 25, accuracy: 0.0001)
    }

    func testWatchedPercentClampsToHundred() {
        let p = WatchProgressMath.watchedPercent(
            position: 5000, engineDuration: 1000, itemRuntime: nil)
        XCTAssertEqual(p, 100, accuracy: 0.0001)
    }

    func testWatchedPercentZeroForInvalidPosition() {
        XCTAssertEqual(WatchProgressMath.watchedPercent(
            position: -1, engineDuration: 1000, itemRuntime: nil), 0)
        XCTAssertEqual(WatchProgressMath.watchedPercent(
            position: .nan, engineDuration: 1000, itemRuntime: nil), 0)
    }

    func testWatchedPercentZeroWhenNoDurationKnown() {
        let p = WatchProgressMath.watchedPercent(
            position: 500, engineDuration: 0, itemRuntime: nil)
        XCTAssertEqual(p, 0)
    }
}
