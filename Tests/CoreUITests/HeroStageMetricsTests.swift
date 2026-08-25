import CoreGraphics
import XCTest
@testable import CoreUI

/// Coverage for the portrait Home hero's proportions.
///
/// The hero is sized to the window rather than to a constant so its metadata
/// sits low on every phone while the row underneath still peeks — two
/// requirements a fixed point height cannot hold at once across a 4.7" and a
/// 6.9" screen. Both are asserted here rather than left to a screenshot.
final class HeroStageMetricsTests: XCTestCase {

    /// The shortest device the app runs on, a common mid-size, and the largest.
    private let windowHeights: [CGFloat] = [667, 844, 956]

    private func height(
        window: CGFloat?,
        accessibilityExtra: CGFloat = 0
    ) -> CGFloat {
        HeroStageMetrics.portraitHomeHeight(
            windowHeight: window,
            fallback: 610,
            accessibilityExtra: accessibilityExtra
        )
    }

    func testLeavesTheNextRowPeekingOnEveryPhone() {
        for window in windowHeights {
            let hero = height(window: window)
            XCTAssertLessThan(hero, window, "window \(window)")
            // A row heading plus a slice of card. Less than this and the peek
            // reads as an accident rather than as "there is more down here".
            XCTAssertGreaterThanOrEqual(
                window - hero,
                100,
                "window \(window)"
            )
        }
    }

    func testGrowsWithThePhone() {
        XCTAssertGreaterThan(height(window: 956), height(window: 844))
    }

    func testFallsBackUntilTheWindowHasBeenMeasured() {
        XCTAssertEqual(height(window: nil), 610)
        XCTAssertEqual(
            height(window: 0, accessibilityExtra: 160),
            770
        )
    }

    /// The clamp keeps the hero sane in an unusually tall container, but must
    /// never withhold room that large text needs.
    func testDynamicTypeAllowanceSurvivesTheClamp() {
        XCTAssertEqual(
            height(window: 4000, accessibilityExtra: 160),
            HeroStageMetrics.portraitHomeMaximumHeight + 160
        )
    }

    func testShortWindowKeepsTheFloor() {
        XCTAssertEqual(
            height(window: 568),
            HeroStageMetrics.portraitHomeMinimumHeight
        )
    }

    /// The taller stage is paid for by the mirror, not by cropping the picture
    /// harder — which is the whole reason the mirror is there.
    func testMirrorsTheShortfallInsteadOfCroppingIt() {
        let geometry = HeroStageMetrics.geometry(width: 440, height: 727)
        XCTAssertGreaterThan(geometry.reflectionHeight, 0)
        XCTAssertEqual(
            geometry.pictureHeight + geometry.reflectionHeight,
            727,
            accuracy: 0.001
        )
        // The picture stands at the stage's own WIDTH times the hero's picture
        // proportion — it never reads the stage's height.
        XCTAssertEqual(
            geometry.pictureHeight,
            440 / HeroStageMetrics.portraitPictureAspectRatio,
            accuracy: 0.001
        )
    }

    /// A stage stretched for accessibility text would otherwise end up a third
    /// reflection, which stops reading as one and starts reading as a second,
    /// upside-down picture.
    func testCapsHowMuchOfTheStageTheMirrorMayTake() {
        let geometry = HeroStageMetrics.geometry(width: 393, height: 900)
        let total = geometry.pictureHeight + geometry.reflectionHeight
        let share = geometry.reflectionHeight / total
        XCTAssertGreaterThan(share, 0)
        XCTAssertLessThanOrEqual(
            share,
            HeroStageMetrics.maximumReflectionShare + 0.001
        )
    }

    /// A stage no taller than the picture is just an ordinary hero.
    func testNoMirrorWhenThePictureAlreadyFillsTheStage() {
        let geometry = HeroStageMetrics.geometry(width: 440, height: 400)
        XCTAssertEqual(geometry.reflectionHeight, 0)
        XCTAssertEqual(HeroStageMetrics.sideCrop(width: 440, height: 400), 0)
    }

    func testDegenerateSizesDoNotCrop() {
        XCTAssertEqual(HeroStageMetrics.sideCrop(width: 0, height: 700), 0)
        XCTAssertEqual(HeroStageMetrics.sideCrop(width: 393, height: 0), 0)
    }
}
