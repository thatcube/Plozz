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

    // MARK: The bottom dissolve

    /// Dark mode holds the picture whole down to the mirror line and melts the
    /// reflection; light mode starts a little earlier because a pale page
    /// swallows the artwork's edge sooner.
    private func meltStart(
        width: CGFloat,
        height: CGFloat,
        dark: Bool = true
    ) -> CGFloat {
        HeroStageMetrics.meltStart(
            width: width,
            height: height,
            mirrorScale: dark ? 1.0 : 0.86,
            floor: dark ? 0.62 : 0.38
        )
    }

    /// The regression this exists for.
    ///
    /// An iPhone SE (3rd generation) is 375pt wide with a 520pt hero, so the
    /// picture (375 ÷ 5:7 = 525pt) is already taller than the stage and there is
    /// NO mirror band — the mirror line sits at 1.0. Tying the melt to it gave
    /// the dissolve the last ~40pt of the hero, which read as a guillotine rather
    /// than a melt. Every phone must get a real dissolve whether or not it has a
    /// reflection to spend it on.
    func testNarrowPhoneWithNoMirrorStillGetsARealDissolve() {
        let height: CGFloat = 520
        let geometry = HeroStageMetrics.geometry(width: 375, height: height)
        // Precondition: this is genuinely the no-mirror case.
        XCTAssertEqual(geometry.reflectionHeight, 0)
        XCTAssertEqual(geometry.reflectionStart, 1)

        let span = (1 - meltStart(width: 375, height: height)) * height
        XCTAssertGreaterThanOrEqual(span, HeroStageMetrics.minimumMeltSpan - 0.001)
    }

    /// Not just the SE: no supported phone may end up with a hard cut.
    func testEveryPhoneGetsAtLeastTheMinimumMeltSpan() {
        // width × hero height for the SE, a 6.1" and a 6.9".
        let stages: [(CGFloat, CGFloat)] = [(375, 520), (402, 664), (440, 727)]
        for (width, height) in stages {
            for dark in [true, false] {
                let start = meltStart(width: width, height: height, dark: dark)
                let span = (1 - start) * height
                XCTAssertGreaterThanOrEqual(
                    span,
                    HeroStageMetrics.minimumMeltSpan - 0.001,
                    "\(width)x\(height) dark=\(dark)"
                )
                XCTAssertGreaterThan(start, 0, "\(width)x\(height)")
                XCTAssertLessThan(start, 1, "\(width)x\(height)")
            }
        }
    }

    /// Where there IS a mirror, the picture is still kept whole down to it — the
    /// floor must not drag the melt up into the photograph.
    func testKeepsThePictureWholeDownToTheMirrorLineWhenThereIsRoom() {
        let height: CGFloat = 727
        let mirrorLine = HeroStageMetrics
            .geometry(width: 440, height: height)
            .reflectionStart
        XCTAssertLessThan(mirrorLine, 1)

        let start = meltStart(width: 440, height: height)
        // Starts no earlier than the reflection begins, within the span the
        // minimum-melt guarantee is allowed to pull it back by.
        XCTAssertGreaterThan(start, 0.7)
        XCTAssertLessThanOrEqual(start, mirrorLine + 0.001)
    }

    /// A light page needs the image to give up sooner than a dark one does.
    func testLightModeStartsNoLaterThanDark() {
        for (width, height) in [(375.0 as CGFloat, 520.0 as CGFloat), (440, 727)] {
            XCTAssertLessThanOrEqual(
                meltStart(width: width, height: height, dark: false),
                meltStart(width: width, height: height, dark: true) + 0.001,
                "\(width)x\(height)"
            )
        }
    }

    /// The guarantee must not be able to eat the hero: on an absurdly short
    /// stage it is capped at half rather than pulling the start to zero.
    func testMinimumMeltSpanNeverEatsMoreThanHalfTheHero() {
        XCTAssertEqual(meltStart(width: 375, height: 100), 0.5, accuracy: 0.001)
    }

    func testMeltStartFallsBackOnDegenerateSizes() {
        XCTAssertEqual(meltStart(width: 0, height: 520), 0.62)
        XCTAssertEqual(meltStart(width: 375, height: 0), 0.62)
    }
}
