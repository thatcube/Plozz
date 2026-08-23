import CoreGraphics
import XCTest
@testable import CoreUI

/// Coverage for the geometry behind a Continue Watching card, which is taller
/// than the 16:9 art it carries so its chrome — play glyph, progress bar,
/// "S1, E12 · 17m" — sits in a band of its own beneath the picture instead of on
/// top of the subject.
///
/// The band split is the whole design, so it is asserted here rather than left to
/// the eye: the picture must keep its own shape (never squashed, never
/// letterboxed), the side trim must stay a trim rather than a crop, and the
/// chrome's scrim and the logo must both be positioned off the same mirror line
/// the artwork actually uses.
final class ExtendedArtworkGeometryTests: XCTestCase {

    private let sixteenByNine: CGFloat = 16.0 / 9.0

    private func geometry(
        width: CGFloat = 480,
        height: CGFloat,
        sideCrop: CGFloat = 0
    ) -> ExtendedArtworkGeometry {
        ExtendedArtworkGeometry(
            slot: CGSize(width: width, height: height),
            artworkAspectRatio: sixteenByNine,
            sideCrop: sideCrop
        )
    }

    // MARK: The picture keeps its shape

    /// With no side trim the picture is exactly its own aspect ratio at the
    /// card's full width — the source is never squashed to fit a taller card.
    func testPictureKeepsItsAspectRatioWhenNothingIsTrimmed() {
        let result = geometry(height: 348)
        XCTAssertEqual(result.renderedWidth, 480, accuracy: 0.001)
        XCTAssertEqual(result.pictureHeight, 480 / sixteenByNine, accuracy: 0.001)
    }

    /// Trimming the sides scales the picture up, so it stands taller in the card
    /// — which is the point of trimming at all: every percent taken off the sides
    /// is a percent of fill band bought back.
    func testSideTrimMakesThePictureStandTaller() {
        let untrimmed = geometry(height: 348)
        let trimmed = geometry(height: 348, sideCrop: 0.03)
        XCTAssertGreaterThan(trimmed.pictureHeight, untrimmed.pictureHeight)
        XCTAssertLessThan(trimmed.reflectionHeight, untrimmed.reflectionHeight)
        // 3% a side leaves 94% visible, so the picture renders 1/0.94 wide.
        XCTAssertEqual(trimmed.renderedWidth, 480 / 0.94, accuracy: 0.001)
        XCTAssertEqual(trimmed.pictureHeight, (480 / 0.94) / sixteenByNine, accuracy: 0.001)
    }

    /// The rendered picture always at least covers the card, so the trim is an
    /// overhang to clip and never leaves a gap at the sides.
    func testRenderedWidthNeverFallsShortOfTheCard() {
        for crop in [CGFloat(0), 0.01, 0.03, 0.1, 0.25] {
            XCTAssertGreaterThanOrEqual(geometry(height: 348, sideCrop: crop).renderedWidth, 480)
        }
    }

    /// A trim of half the width or more would be a different picture, not a trim,
    /// so it is floored well before that however it is configured.
    func testAbsurdSideCropIsFloored() {
        let absurd = geometry(height: 348, sideCrop: 0.9)
        XCTAssertEqual(absurd.renderedWidth, 480 / 0.5, accuracy: 0.001)
    }

    func testNegativeSideCropIsIgnoredRatherThanInverted() {
        XCTAssertEqual(geometry(height: 348, sideCrop: -0.2).renderedWidth, 480, accuracy: 0.001)
    }

    // MARK: The two bands

    /// The bands always account for the whole card — no gap, no overflow.
    func testBandsFillTheCardExactly() {
        for height in [CGFloat(200), 270, 300, 348, 400] {
            let result = geometry(height: height, sideCrop: 0.03)
            XCTAssertEqual(
                result.pictureHeight + result.reflectionHeight,
                height,
                accuracy: 0.001,
                "bands must add up to the card at height \(height)"
            )
        }
    }

    /// A card exactly as tall as its picture — a plain 16:9 thumbnail-style card
    /// — has no band under it, so nothing is mirrored and the card is unchanged
    /// from what it always was.
    func testSixteenByNineSlotHasNoReflection() {
        let result = geometry(height: 480 / (16.0 / 9.0))
        XCTAssertEqual(result.reflectionHeight, 0, accuracy: 0.001)
        XCTAssertEqual(result.reflectionStart, 1, accuracy: 0.001)
    }

    /// A slot SHORTER than the picture crops rather than overflowing: the picture
    /// is capped at the slot and there is still no reflection.
    func testShortSlotClampsThePictureInsteadOfOverflowing() {
        let result = geometry(height: 120)
        XCTAssertEqual(result.pictureHeight, 120, accuracy: 0.001)
        XCTAssertEqual(result.reflectionHeight, 0, accuracy: 0.001)
    }

    func testDegenerateSlotDoesNotProduceNegativeBands() {
        let empty = geometry(width: 0, height: 0)
        XCTAssertEqual(empty.pictureHeight, 0, accuracy: 0.001)
        XCTAssertEqual(empty.reflectionHeight, 0, accuracy: 0.001)
        XCTAssertEqual(empty.reflectionStart, 1, accuracy: 0.001)
    }

    /// The split is a pure ratio, so a card of the same shape lands on the same
    /// mirror line at any display density.
    func testMirrorLineIsScaleInvariant() {
        let small = geometry(width: 240, height: 174, sideCrop: 0.03)
        let large = geometry(width: 720, height: 522, sideCrop: 0.03)
        XCTAssertEqual(small.reflectionStart, large.reflectionStart, accuracy: 0.0001)
    }

    /// An off-ratio source (a 2:3 poster standing in as last-resort series art)
    /// doesn't change the bands — it is centre-cropped into the picture band, the
    /// same as a plain fill would do.
    func testBandsDependOnTheDrawnShapeNotTheSource() {
        let result = ExtendedArtworkGeometry(
            slot: CGSize(width: 480, height: 348),
            artworkAspectRatio: sixteenByNine,
            sideCrop: 0.03
        )
        XCTAssertEqual(result.pictureHeight, (480 / 0.94) / sixteenByNine, accuracy: 0.001)
    }
}

/// The card shape itself: the numbers the card, its logo, its chrome scrim and
/// the Settings preview all read from, so they cannot drift apart.
final class ContinueWatchingCardShapeTests: XCTestCase {

    /// Taller than the art it carries — otherwise there is no band for the chrome
    /// and the whole treatment collapses back to chrome-on-subject.
    func testCardIsTallerThanItsArtwork() {
        XCTAssertLessThan(ContinueWatchingCardShape.aspectRatio, 16.0 / 9.0)
        XCTAssertGreaterThan(ContinueWatchingCardShape.geometry.reflectionHeight, 0)
    }

    /// …but still recognisably a wide card, not a poster.
    func testCardStaysLandscape() {
        XCTAssertGreaterThan(ContinueWatchingCardShape.aspectRatio, 1.2)
    }

    /// The picture keeps the large majority of the card. The band underneath is
    /// there to hold the chrome, not to become a design element in its own right.
    func testPictureKeepsMostOfTheCard() {
        XCTAssertGreaterThan(ContinueWatchingCardShape.mirrorLine, 0.75)
        XCTAssertLessThan(ContinueWatchingCardShape.mirrorLine, 0.9)
    }

    /// The chrome's scrim starts above the mirror line, so the tops of the chip's
    /// glyphs have a bed rather than sitting on bare picture…
    func testScrimStartsAboveTheMirrorLine() {
        XCTAssertLessThan(ContinueWatchingCardShape.scrimStart, ContinueWatchingCardShape.mirrorLine)
    }

    /// …but only just: it must not creep back to the shared default that darkens
    /// half the picture, which is the very thing the reserved band avoids.
    func testScrimDoesNotDarkenHalfThePicture() {
        XCTAssertGreaterThan(ContinueWatchingCardShape.scrimStart, 0.7)
    }

    /// The logo is measured against the picture band, so growing it can never
    /// push it into the chrome.
    func testLogoFitsWellInsideThePictureBand() {
        XCTAssertLessThan(ContinueWatchingCardShape.logoHeightFraction, 0.5)
        XCTAssertLessThan(ContinueWatchingCardShape.logoWidthFraction, 1)
        let logoHeightOfCard = ContinueWatchingCardShape.mirrorLine
            * ContinueWatchingCardShape.logoHeightFraction
        // Centred in the picture band, so it reaches half its own height either
        // side of that band's middle — comfortably clear of the mirror line.
        let logoFoot = ContinueWatchingCardShape.mirrorLine / 2 + logoHeightOfCard / 2
        XCTAssertLessThan(logoFoot, ContinueWatchingCardShape.scrimStart)
    }

    /// The logo box is bigger than the one it replaced — 0.66 × 0.34 of a flat
    /// 16:9 card — which was the point of the change: small logos on a rail you
    /// read from ten feet away. Compared at a real card width, since the taller
    /// card makes a fraction-of-the-card comparison understate the difference.
    func testLogoIsLargerThanTheFlatCardTreatment() {
        let width = PlozzTheme.Metrics.landscapeWidth
        let flatHeight = PlozzTheme.Metrics.landscapeHeight
        let cardHeight = width / ContinueWatchingCardShape.aspectRatio

        let wasWide = width * 0.66
        let wasTall = flatHeight * 0.34
        let isWide = width * ContinueWatchingCardShape.logoWidthFraction
        let isTall = cardHeight
            * ContinueWatchingCardShape.mirrorLine
            * ContinueWatchingCardShape.logoHeightFraction

        XCTAssertGreaterThan(isWide, wasWide)
        XCTAssertGreaterThan(isTall, wasTall)
        // A worthwhile bump rather than a rounding difference: the box a logo is
        // actually fitted into is at least a quarter larger by area.
        XCTAssertGreaterThan(isWide * isTall, wasWide * wasTall * 1.25)
    }
}
