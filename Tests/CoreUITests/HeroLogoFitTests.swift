import CoreGraphics
import XCTest
@testable import CoreUI

/// Coverage for `HeroLogoFit`, which sizes a hero wordmark by **area** so a show's
/// presence on screen doesn't come down to the shape of its logo.
///
/// The shapes here are measured from real logos in a live library: a very wide
/// wordmark ("The Old Man"), ordinary wide ones ("Reacher", "Avatar"), a squarish
/// one ("17 Again"), and a tall poster-style one ("Sleepy Princess in the Demon
/// Castle"). Under a plain width-and-height cap these spanned a 3.4× range in area.
final class HeroLogoFitTests: XCTestCase {

    private let slot = CGSize(width: 496, height: 160)

    private func fit(aspect: CGFloat) -> CGSize {
        HeroLogoFit.fittedSize(
            for: CGSize(width: 1000, height: 1000 * aspect),
            maxWidth: slot.width,
            maxHeight: slot.height
        )
    }

    private func area(_ size: CGSize) -> CGFloat { size.width * size.height }

    /// Aspects (height ÷ width) measured from the real logos.
    private let veryWide: CGFloat = 0.11   // The Old Man
    private let wide: CGFloat = 0.25       // Avatar
    private let squarish: CGFloat = 0.85   // 17 Again
    private let tall: CGFloat = 1.40       // Sleepy Princess

    // MARK: The point of the whole type

    func testEveryShapeLandsWithinHalfAStopOfTheSame() {
        let areas = [veryWide, 0.22, wide, squarish, tall].map { area(fit(aspect: $0)) }
        let spread = areas.max()! / areas.min()!
        XCTAssertLessThan(spread, 1.6, "was 3.4x under a plain height cap")
    }

    func testATallLogoIsNoLongerShrunkForBeingTall() {
        // The worst case: a height cap collapsed this to 114x160 (18k), less than a
        // third of a wide wordmark's area.
        let size = fit(aspect: tall)
        XCTAssertGreaterThan(area(size), 40_000)
        XCTAssertGreaterThan(size.width, 160)
    }

    func testAVeryWideLogoIsNoLongerAThinStrip() {
        // Filling the width left this 55pt tall — legible, but weightless.
        let size = fit(aspect: veryWide)
        XCTAssertGreaterThan(area(size), 40_000)
        XCTAssertGreaterThan(size.height, 60)
    }

    // MARK: Preserving what already looked right

    func testAnOrdinaryWideWordmarkIsUnchanged() {
        // The shape that reads correctly today must not move, or the fix trades one
        // complaint for another.
        let size = fit(aspect: wide)
        XCTAssertEqual(size.width, 496, accuracy: 1)
        XCTAssertEqual(size.height, 124, accuracy: 1)
    }

    // MARK: Bounds

    func testNeitherDimensionEscapesItsFlexCeiling() {
        for aspect in [0.05, 0.11, 0.25, 0.85, 1.4, 3.0] {
            let size = fit(aspect: CGFloat(aspect))
            XCTAssertLessThanOrEqual(size.width, slot.width * HeroLogoFit.widthFlex + 0.5)
            XCTAssertLessThanOrEqual(size.height, slot.height * HeroLogoFit.heightFlex + 0.5)
        }
    }

    func testTheDrawnAspectRatioIsNeverDistorted() {
        for aspect in [0.05, 0.11, 0.25, 0.85, 1.4, 3.0] {
            let size = fit(aspect: CGFloat(aspect))
            XCTAssertEqual(size.height / size.width, CGFloat(aspect), accuracy: 0.001)
        }
    }

    func testASmallSourceIsScaledUpRatherThanLeftTiny() {
        // Logo art arrives from several providers at different resolutions; sizing by
        // the source's own pixels made one show bold and another tiny for reasons
        // unrelated to how either logo looks.
        let tiny = HeroLogoFit.fittedSize(
            for: CGSize(width: 100, height: 25),
            maxWidth: slot.width,
            maxHeight: slot.height
        )
        let large = HeroLogoFit.fittedSize(
            for: CGSize(width: 2000, height: 500),
            maxWidth: slot.width,
            maxHeight: slot.height
        )
        XCTAssertEqual(tiny.width, large.width, accuracy: 0.5)
        XCTAssertEqual(tiny.height, large.height, accuracy: 0.5)
    }

    func testADegenerateSizeFallsBackToTheSlot() {
        let zero = HeroLogoFit.fittedSize(
            for: .zero,
            maxWidth: slot.width,
            maxHeight: slot.height
        )
        XCTAssertEqual(zero, slot)
    }
}

/// Coverage for the **ink** correction, which is the variable area-fitting can't
/// see.
///
/// Fitting by area gives every wordmark the same box to fill. It cannot tell how
/// much of that box is painted: a heavy slab face may cover half of it and a thin
/// script an eighth, so at identical area the slab reads as twice the logo. Ink
/// coverage separates them, and it is measured for free in the pixel pass that
/// already trims and tones each logo.
final class HeroLogoInkTests: XCTestCase {

    private let slot = CGSize(width: 300, height: 120)

    /// A logo carrying the reference amount of ink is left exactly as it was.
    func testReferenceInkIsUnchanged() {
        XCTAssertEqual(HeroLogoFit.inkScale(coverage: HeroLogoFit.referenceInk), 1, accuracy: 0.001)
    }

    /// Thin art is drawn larger, heavy art smaller.
    func testThinArtGrowsAndHeavyArtShrinks() {
        XCTAssertGreaterThan(HeroLogoFit.inkScale(coverage: 0.15), 1)
        XCTAssertLessThan(HeroLogoFit.inkScale(coverage: 0.55), 1)
    }

    /// Monotonic while the correction applies: more ink is never rewarded with
    /// more size. (Past `inkFadeStart` the curve deliberately eases back toward
    /// neutral, which is covered separately below.)
    func testScaleFallsMonotonicallyAsInkRises() {
        var previous = CGFloat.greatestFiniteMagnitude
        for step in 1...40 {
            let coverage = Double(step) / 40
            guard coverage <= HeroLogoFit.inkFadeStart else { break }
            let scale = HeroLogoFit.inkScale(coverage: coverage)
            XCTAssertLessThanOrEqual(scale, previous)
            previous = scale
        }
    }

    /// No discontinuity anywhere in the curve — the whole point is to remove
    /// visible size jumps between similar logos, not to introduce one.
    func testCurveIsContinuousAcrossItsWholeRange() {
        var previous = HeroLogoFit.inkScale(coverage: 0.001)
        for step in 1...1000 {
            let scale = HeroLogoFit.inkScale(coverage: Double(step) / 1000)
            XCTAssertLessThan(abs(scale - previous), 0.02, "step at coverage \(Double(step) / 1000)")
            previous = scale
        }
    }

    /// A nudge, not an equalisation — a heavy face genuinely *is* a bolder logo
    /// and should still read as one. Equal total ink would demand 1.41× for a
    /// logo carrying half the reference; the damped curve asks for far less.
    func testCorrectionIsDampedNotEqualising() {
        let half = HeroLogoFit.inkScale(coverage: HeroLogoFit.referenceInk / 2)
        XCTAssertGreaterThan(half, 1.15)
        XCTAssertLessThan(half, 1.35)
    }

    /// Clamped at both ends, so one badly-measured logo can't dominate a rail.
    ///
    /// The clamp is also what makes a vanishingly small measurement safe, which is
    /// why there is no floor guard: a guard would itself be a cliff, drawing a
    /// logo at 0.019 coverage a fifth smaller than one at 0.021.
    func testScaleIsClampedAtBothEnds() {
        for coverage in [0.0001, 0.005, 0.03, 0.94, 0.99] {
            let scale = HeroLogoFit.inkScale(coverage: coverage)
            XCTAssertGreaterThanOrEqual(scale, HeroLogoFit.minInkScale)
            XCTAssertLessThanOrEqual(scale, HeroLogoFit.maxInkScale)
        }
    }

    /// A near-solid frame is not a wordmark — it is a plate that survived
    /// stripping — so the correction is gone by the time coverage reaches it.
    /// Same for a measurement of essentially nothing.
    func testNonWordmarkCoverageIsLeftAlone() {
        XCTAssertEqual(HeroLogoFit.inkScale(coverage: 0.95), 1, accuracy: 0.0001)
        XCTAssertEqual(HeroLogoFit.inkScale(coverage: 0.0), 1, accuracy: 0.0001)
        XCTAssertEqual(HeroLogoFit.inkScale(coverage: 1.0), 1, accuracy: 0.0001)
    }

    /// …and it *eases* out rather than switching off at a line.
    ///
    /// This is what the monotonicity test caught: a hard cutoff meant two logos a
    /// hair either side of it were drawn at noticeably different sizes — a step in
    /// exactly the curve that exists to remove steps.
    func testCorrectionFadesOutSmoothlyRatherThanCuttingOff() {
        let justInside = HeroLogoFit.inkScale(coverage: HeroLogoFit.inkFadeEnd - 0.01)
        XCTAssertEqual(justInside, 1, accuracy: 0.02, "no jump at the far end of the fade")
        // Across the whole fade the curve only ever moves toward neutral.
        var previous = HeroLogoFit.inkScale(coverage: HeroLogoFit.inkFadeStart)
        for step in 1...20 {
            let coverage = HeroLogoFit.inkFadeStart
                + (HeroLogoFit.inkFadeEnd - HeroLogoFit.inkFadeStart) * Double(step) / 20
            let scale = HeroLogoFit.inkScale(coverage: coverage)
            XCTAssertGreaterThanOrEqual(scale, previous - 0.0001)
            XCTAssertLessThanOrEqual(scale, 1.0001)
            previous = scale
        }
    }

    /// Omitting the measurement reproduces the previous behaviour exactly, so any
    /// caller that has no coverage to give is unaffected.
    func testDefaultCoverageMatchesTheUncorrectedFit() {
        let image = CGSize(width: 1000, height: 260)
        let plain = HeroLogoFit.fittedSize(for: image, maxWidth: slot.width, maxHeight: slot.height)
        let explicit = HeroLogoFit.fittedSize(
            for: image, maxWidth: slot.width, maxHeight: slot.height, coverage: 1
        )
        XCTAssertEqual(plain.width, explicit.width, accuracy: 0.001)
        XCTAssertEqual(plain.height, explicit.height, accuracy: 0.001)
    }

    /// The correction reaches the drawn size: two logos of the SAME shape but
    /// different ink are drawn at different sizes, the thinner one larger.
    func testInkChangesTheDrawnSizeForIdenticalShapes() {
        let image = CGSize(width: 1000, height: 300)
        let thin = HeroLogoFit.fittedSize(
            for: image, maxWidth: slot.width, maxHeight: slot.height, coverage: 0.14
        )
        let heavy = HeroLogoFit.fittedSize(
            for: image, maxWidth: slot.width, maxHeight: slot.height, coverage: 0.52
        )
        XCTAssertGreaterThan(thin.width * thin.height, heavy.width * heavy.height)
    }

    /// It narrows the spread rather than inverting it: after correction the thin
    /// logo must not overshoot past the heavy one's original weight.
    func testInkNarrowsTheSpreadRatherThanInvertingIt() {
        let image = CGSize(width: 1000, height: 300)
        func inkArea(_ coverage: Double) -> CGFloat {
            let size = HeroLogoFit.fittedSize(
                for: image, maxWidth: slot.width, maxHeight: slot.height, coverage: coverage
            )
            // Area actually painted = drawn area × ink.
            return size.width * size.height * CGFloat(coverage)
        }
        let thin = inkArea(0.14)
        let heavy = inkArea(0.52)
        XCTAssertLessThan(thin, heavy, "a thin logo must not end up inkier than a heavy one")

        func plainInkArea(_ coverage: Double) -> CGFloat {
            let size = HeroLogoFit.fittedSize(for: image, maxWidth: slot.width, maxHeight: slot.height)
            return size.width * size.height * CGFloat(coverage)
        }
        let before = plainInkArea(0.52) / plainInkArea(0.14)
        let after = heavy / thin
        XCTAssertLessThan(after, before, "the gap in painted ink must close, not widen")
    }

    /// **The ceilings never move.** They are what keeps a logo clear of the card's
    /// edges and the chrome below, and those distances belong to the layout — not
    /// to how much of its own box a logo happens to paint. A thin wordmark may be
    /// given more area; it may not be given permission to reach further.
    func testInkNeverPushesALogoPastItsCeilings() {
        for coverage in [0.05, 0.14, 0.32, 0.6, 0.9] {
            let wide = HeroLogoFit.fittedSize(
                for: CGSize(width: 1000, height: 90),
                maxWidth: slot.width, maxHeight: slot.height, coverage: coverage
            )
            XCTAssertLessThanOrEqual(
                wide.width,
                slot.width * HeroLogoFit.widthFlex + 0.001,
                "ink must not widen a logo past the width ceiling at coverage \(coverage)"
            )
            let tall = HeroLogoFit.fittedSize(
                for: CGSize(width: 300, height: 1000),
                maxWidth: slot.width, maxHeight: slot.height, coverage: coverage
            )
            XCTAssertLessThanOrEqual(
                tall.height,
                slot.height * HeroLogoFit.heightFlex + 0.001,
                "ink must not heighten a logo past the height ceiling at coverage \(coverage)"
            )
        }
    }
}

/// Coverage for the **width pin** — the trade that turns a nominal width budget
/// into a hard cap on what is actually drawn, without shrinking anything.
///
/// `fittedSize` reads its box as a budget and lets a wide shape flex to
/// `widthFlex` past it, so every caller that documented "never wider than this
/// column" was in fact drawing a quarter wider than the column. Handing over a
/// narrower box alone would fix the overrun and shrink every logo with it, since
/// the fit sizes on area — so the width the cap takes is returned as height.
final class HeroLogoPinnedBoxTests: XCTestCase {

    /// A hero column: the width the buttons and overview beneath the logo occupy.
    private let column = CGSize(width: 620, height: 200)

    private func pinned() -> CGSize {
        HeroLogoFit.pinnedBox(budget: column, drawnWidth: column.width)
    }

    private func drawn(aspect: CGFloat, in box: CGSize, coverage: Double = 1) -> CGSize {
        HeroLogoFit.fittedSize(
            for: CGSize(width: 1000, height: 1000 * aspect),
            maxWidth: box.width,
            maxHeight: box.height,
            coverage: coverage
        )
    }

    /// The whole point of the trade: the area the fit solves for is untouched, so
    /// pinning the width costs no logo any size.
    func testTheTradePreservesTheBudgetArea() {
        let box = pinned()
        XCTAssertEqual(
            box.width * box.height,
            column.width * column.height,
            accuracy: 0.5,
            "the width the pin takes must come back as height"
        )
        XCTAssertLessThan(box.width, column.width, "the nominal box must narrow")
        XCTAssertGreaterThan(box.height, column.height, "and grow taller by the same factor")
    }

    /// The cap the callers actually promised. Checked across the full range of
    /// shapes *and* ink weights, since ink adjusts the area target and an earlier
    /// version let a thin wordmark buy its way past the ceiling.
    func testNoLogoIsEverDrawnWiderThanTheColumn() {
        let box = pinned()
        for aspect in [0.08, 0.11, 0.18, 0.25, 0.55, 0.85, 1.4, 2.2] as [CGFloat] {
            for coverage in [0.03, 0.12, 0.32, 0.55, 0.95] {
                let size = drawn(aspect: aspect, in: box, coverage: coverage)
                XCTAssertLessThanOrEqual(
                    size.width,
                    column.width + 0.001,
                    "aspect \(aspect) at coverage \(coverage) overran the column"
                )
            }
        }
    }

    /// Without the pin the same shapes overran — otherwise the test above proves
    /// nothing about the change.
    func testTheUnpinnedBoxDidOverrunTheColumn() {
        let size = drawn(aspect: 0.18, in: column)
        XCTAssertGreaterThan(
            size.width,
            column.width,
            "a wide wordmark used to flex past the column it was capped to"
        )
    }

    /// Why the row reads as consistent: every wordmark wide enough to reach the
    /// cap is drawn at the *same* width, so a logo's aspect ratio stops deciding
    /// how much of the screen it takes.
    func testEveryWideWordmarkLandsAtTheSameDrawnWidth() {
        let box = pinned()
        let widths = [0.08, 0.11, 0.18].map { drawn(aspect: $0, in: box).width }
        XCTAssertEqual(widths.max()! - widths.min()!, 0, accuracy: 0.001)
        XCTAssertEqual(widths[0], column.width, accuracy: 0.001)
    }

    /// Ink still cannot buy a wide logo more width — but it is not silently
    /// cancelled either: the same correction keeps working on the shapes that
    /// never reach the cap.
    func testInkStillMovesTheShapesThatDoNotReachTheCap() {
        let box = pinned()
        let thin = drawn(aspect: 0.85, in: box, coverage: 0.12)
        let heavy = drawn(aspect: 0.85, in: box, coverage: 0.55)
        XCTAssertGreaterThan(
            thin.width * thin.height,
            heavy.width * heavy.height,
            "a sparse wordmark must still be drawn larger than a dense one"
        )
    }

    /// A shape that reaches neither ceiling in either box is drawn identically —
    /// proof the trade redistributes the budget rather than changing it.
    func testAShapeThatClampsInNeitherBoxIsUnchanged() {
        let before = drawn(aspect: 0.55, in: column)
        let after = drawn(aspect: 0.55, in: pinned())
        XCTAssertEqual(before.width, after.width, accuracy: 0.001)
        XCTAssertEqual(before.height, after.height, accuracy: 0.001)
    }

    /// The give-back is boundable, for a caller with something below the logo it
    /// must not reach — the Continue Watching card's mirror line, say.
    func testMaxHeightBoundsTheGiveBack() {
        let box = HeroLogoFit.pinnedBox(
            budget: column,
            drawnWidth: column.width,
            maxHeight: 210
        )
        XCTAssertEqual(box.height, 210, accuracy: 0.001)
        XCTAssertLessThan(box.width * box.height, column.width * column.height)
    }

    /// A budget already narrower than the cap allows is left alone — the pin is a
    /// ceiling, not a resize.
    func testABudgetInsideTheCapIsUntouched() {
        let box = HeroLogoFit.pinnedBox(budget: column, drawnWidth: 10_000)
        XCTAssertEqual(box.width, column.width, accuracy: 0.001)
        XCTAssertEqual(box.height, column.height, accuracy: 0.001)
    }

    /// Degenerate input returns the budget rather than a divide-by-zero.
    func testDegenerateInputReturnsTheBudget() {
        for bad in [CGSize(width: 0, height: 200), CGSize(width: 620, height: 0)] {
            XCTAssertEqual(HeroLogoFit.pinnedBox(budget: bad, drawnWidth: 620), bad)
        }
        XCTAssertEqual(HeroLogoFit.pinnedBox(budget: column, drawnWidth: 0), column)
    }
}

/// Coverage for the logo lift — the second of the card's two remedies.
///
/// Dimming the backdrop only works in one direction: it pulls the picture down
/// and away from the logo, and runs out once the picture is already black. The
/// lift pulls the other way. Which one a card gets depends on where the room is.
final class LogoToneLiftTests: XCTestCase {

    private func lift(needsHelp: Double?, luminance: Double) -> Double {
        LogoToneLift.lift(needsHelp: needsHelp, luminance: luminance)
    }

    /// **The case dimming cannot reach.** House of the Dragon's bronze serif on
    /// near-black fire: the backdrop has no darkness left to give, and the ink has
    /// the whole range to grow into.
    func testDarkLogoInTroubleIsLifted() {
        XCTAssertGreaterThan(lift(needsHelp: 0.36, luminance: 0.34), 0.08)
    }

    /// **The case that proved tone alone is the wrong test.** Lilo & Stitch's red
    /// wordmark is dark by luminance and perfectly readable on open sky. Need — not
    /// darkness — decides, so it is untouched.
    func testDarkButReadableLogoIsLeftAlone() {
        XCTAssertEqual(lift(needsHelp: 0, luminance: 0.30), 0, accuracy: 0.0001)
    }

    /// …and the mirror of it: Boba Fett's metallic type is not dark at all, yet it
    /// disappears into its own warm scene. It gets help too, which the earlier
    /// dark-logo test would have denied it.
    func testBrightLogoInTroubleIsStillHelped() {
        XCTAssertGreaterThan(lift(needsHelp: 0.35, luminance: 0.72), 0)
    }

    /// Headroom bounds it: ink with nowhere brighter to go is never lifted, since
    /// that would only grey the picture around it.
    func testLogoWithNoHeadroomIsNotLifted() {
        XCTAssertEqual(lift(needsHelp: 1, luminance: 1.0), 0, accuracy: 0.0001)
    }

    /// Before the artwork is measured there is nothing to reason from, and
    /// guessing would break one case or the other.
    func testUnmeasuredArtworkIsLeftAlone() {
        XCTAssertEqual(lift(needsHelp: nil, luminance: 0.30), 0, accuracy: 0.0001)
    }

    /// More trouble and more headroom both mean more lift, monotonically.
    func testLiftRisesWithNeedAndWithHeadroom() {
        var previous = -1.0
        for step in 0...20 {
            let value = lift(needsHelp: Double(step) / 20, luminance: 0.34)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
        previous = Double.greatestFiniteMagnitude
        for step in 0...20 {
            let value = lift(needsHelp: 0.5, luminance: Double(step) / 20)
            XCTAssertLessThanOrEqual(value, previous)
            previous = value
        }
    }

    /// Continuous, so two similar cards can't be treated visibly differently.
    func testLiftIsContinuous() {
        var previous = lift(needsHelp: 0, luminance: 0.34)
        for step in 1...200 {
            let value = lift(needsHelp: Double(step) / 200, luminance: 0.34)
            XCTAssertLessThan(abs(value - previous), 0.02)
            previous = value
        }
    }

    /// Capped, so even the worst case cannot wash the ink out.
    func testLiftIsCapped() {
        for luminance in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertLessThanOrEqual(lift(needsHelp: 1, luminance: luminance), LogoToneLift.liftCap)
        }
    }

    /// The lift adds brightness *and* restores saturation, which is the whole
    /// reason it does not bleach: additive brightness alone drifts toward white,
    /// and pushing the chroma back up cancels exactly that drift.
    func testLiftRestoresSaturationRatherThanBleaching() {
        XCTAssertGreaterThan(LogoToneLift.saturationPerLift, 1)
        XCTAssertLessThanOrEqual(LogoToneLift.liftCap, 0.25, "a lift this large would wash the ink out")
    }
}
