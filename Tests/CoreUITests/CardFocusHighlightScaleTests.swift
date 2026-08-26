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

    /// Before a card has been measured the fallback still has to satisfy the rule
    /// for the smallest card in the app, whose outline is proportionally largest.
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
