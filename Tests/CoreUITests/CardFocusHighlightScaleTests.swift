import XCTest
import CoreModels
@testable import CoreUI

#if canImport(SwiftUI)
import SwiftUI

/// The contract behind the "Highlight" focus style: with the focus outline gone,
/// a focused card must still cover at least the ground the outlined card covered
/// — outline included.
final class CardFocusHighlightScaleTests: XCTestCase {
    private typealias Metrics = PlozzTheme.Metrics

    /// The binding case: a borderless poster, whose halo reaches
    /// `circleFocusPadding` past the artwork on every edge.
    func testHighlightCoversTheOutlinedCardOnBothAxes() {
        let artwork = CGSize(width: 280, height: 420)
        let reach: CGFloat = 8
        let outlineScale = Metrics.mediumFocusedCardScale

        let scale = Metrics.highlightFocusScale(
            outlineScale: outlineScale,
            contentSize: artwork,
            outlineReach: reach
        )

        let outlinedWidth = (artwork.width + reach * 2) * outlineScale
        let outlinedHeight = (artwork.height + reach * 2) * outlineScale
        XCTAssertGreaterThanOrEqual(artwork.width * scale, outlinedWidth - 0.001)
        XCTAssertGreaterThanOrEqual(artwork.height * scale, outlinedHeight - 0.001)
    }

    /// The rule has to hold for every shape the app draws, not just the one it
    /// was derived from — a short, wide card's outline is a bigger share of its
    /// height than of its width, and vice versa.
    func testHighlightCoversTheOutlinedCardForEveryCardShape() {
        let shapes: [CGSize] = [
            CGSize(width: 280, height: 420),   // borderless poster
            CGSize(width: 480, height: 270),   // landscape artwork
            CGSize(width: 304, height: 500),   // framed poster, caption included
            CGSize(width: 150, height: 150),   // cast portrait
            CGSize(width: 230, height: 230)    // artist tile
        ]
        for reach in [CGFloat(6), 8, 12] {
            for size in shapes {
                let scale = Metrics.highlightFocusScale(
                    outlineScale: Metrics.focusedCardScale,
                    contentSize: size,
                    outlineReach: reach
                )
                XCTAssertGreaterThanOrEqual(
                    size.width * scale,
                    (size.width + reach * 2) * Metrics.focusedCardScale - 0.001,
                    "width fell short for \(size) at reach \(reach)"
                )
                XCTAssertGreaterThanOrEqual(
                    size.height * scale,
                    (size.height + reach * 2) * Metrics.focusedCardScale - 0.001,
                    "height fell short for \(size) at reach \(reach)"
                )
            }
        }
    }

    /// A card that asked for no lift at all (Reduce Motion) must not be handed
    /// one by the multiplier.
    func testNoLiftRequestedStaysNoLift() {
        XCTAssertEqual(
            Metrics.highlightFocusScale(
                outlineScale: 1,
                contentSize: CGSize(width: 480, height: 270),
                outlineReach: 8
            ),
            1
        )
    }

    /// A card whose outline lives INSIDE its own bounds — every framed card —
    /// loses no ground when that outline stops lighting up, so it must keep
    /// exactly the scale it always had.
    ///
    /// The regression: zero reach fell through to the unmeasured fallback and
    /// grew every framed card by 11% on top of its focus scale, which is the
    /// "framed cards are too big" this was supposed to fix.
    func testNoOutlineReachMeansNoExtraGrowth() {
        for outlineScale in [Metrics.focusedCardScale, Metrics.mediumFocusedCardScale, Metrics.readOnlyFocusedCardScale] {
            XCTAssertEqual(
                Metrics.highlightFocusScale(
                    outlineScale: outlineScale,
                    contentSize: CGSize(width: 304, height: 500),
                    outlineReach: 0
                ),
                outlineScale,
                "a card with nothing outside its bounds must not grow further"
            )
            // Also true before it has been measured.
            XCTAssertEqual(
                Metrics.highlightFocusScale(
                    outlineScale: outlineScale,
                    contentSize: .zero,
                    outlineReach: 0
                ),
                outlineScale
            )
        }
    }

    /// Before a card *with* reach has been measured, the fallback still has to
    /// satisfy the rule for the smallest card in the app, whose outline is
    /// proportionally largest.
    func testUnmeasuredCardFallsBackToASafeGrowth() {
        let scale = Metrics.highlightFocusScale(
            outlineScale: Metrics.mediumFocusedCardScale,
            contentSize: .zero,
            outlineReach: 8
        )
        XCTAssertEqual(scale, Metrics.mediumFocusedCardScale * Metrics.highlightFocusFallbackRatio, accuracy: 0.0001)

        let smallest = CGSize(width: 150, height: 150)
        XCTAssertGreaterThanOrEqual(
            smallest.width * scale,
            (smallest.width + 16) * Metrics.mediumFocusedCardScale - 0.001
        )
    }

    /// Growth is capped so a small or oddly-shaped card can't be blown up into
    /// its neighbours.
    func testGrowthIsCapped() {
        let scale = Metrics.highlightFocusScale(
            outlineScale: Metrics.mediumFocusedCardScale,
            contentSize: CGSize(width: 20, height: 20),
            outlineReach: 12
        )
        XCTAssertEqual(scale, Metrics.mediumFocusedCardScale * Metrics.highlightFocusMaxRatio, accuracy: 0.0001)
    }

    /// The outlined style keeps exactly the animation it has always had; only the
    /// highlight style springs, and it leaves more slowly than it arrives so a
    /// card settles rather than snapping back.
    func testOnlyTheHighlightStyleChangesTheFocusAnimation() {
        let outlinedIn = Metrics.cardFocusAnimation(isFocused: true, focusStyle: .outlined, reduceMotion: false)
        let outlinedOut = Metrics.cardFocusAnimation(isFocused: false, focusStyle: .outlined, reduceMotion: false)
        XCTAssertEqual(outlinedIn, .easeOut(duration: 0.18))
        XCTAssertEqual(outlinedOut, .easeOut(duration: 0.18))

        let highlightIn = Metrics.cardFocusAnimation(isFocused: true, focusStyle: .highlight, reduceMotion: false)
        let highlightOut = Metrics.cardFocusAnimation(isFocused: false, focusStyle: .highlight, reduceMotion: false)
        XCTAssertNotEqual(highlightIn, highlightOut)
        XCTAssertNotEqual(highlightIn, .easeOut(duration: 0.18))

        // Reduce Motion takes the plain ease in either style.
        XCTAssertEqual(
            Metrics.cardFocusAnimation(isFocused: true, focusStyle: .highlight, reduceMotion: true),
            .easeOut(duration: 0.18)
        )
    }
}
#endif
