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

    /// A card at the standard density and default text size.
    static let card: (width: CGFloat, height: CGFloat, stage: CGFloat) = {
        let width = PlozzTheme.Metrics.landscapeWidth * ContinueWatchingCardShape.widthScale
        let height = width / ContinueWatchingCardShape.aspectRatio
        return (width, height, height * ContinueWatchingCardShape.mirrorLine)
    }()

    /// The chip's own inset from the card edge, which the logo's clearance must
    /// at least match.
    static let chipInset = PlozzTheme.Metrics.resumeChipInset


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
    /// there to hold the chrome, not to become a design element in its own right
    /// — past a point the reflection stops reading as the picture having a soft
    /// bottom and starts being a feature the chip then sits on top of.
    func testPictureKeepsMostOfTheCard() {
        XCTAssertGreaterThan(ContinueWatchingCardShape.mirrorLine, 0.8)
        XCTAssertLessThan(ContinueWatchingCardShape.mirrorLine, 0.92)
    }

    /// The shape is *derived* from how much reflection the card should show, so
    /// the two can't disagree — that share is the thing anyone actually chooses.
    func testAspectRatioFollowsTheChosenReflectionShare() {
        let share = PlozzTheme.Metrics.continueWatchingReflectionShare
        let geometry = ContinueWatchingCardShape.geometry
        XCTAssertEqual(
            geometry.reflectionHeight / geometry.pictureHeight,
            share,
            accuracy: 0.001
        )
    }

    /// The scrim starts well up in the picture, not at the mirror line.
    ///
    /// Confining it to the reflection band meant all the darkening had to happen
    /// in the bottom sixth of the card: it arrived fast and piled up near-black at
    /// the foot. A long run is what lets it finish lighter.
    func testScrimRunsWellAboveTheMirrorLine() {
        XCTAssertLessThan(ContinueWatchingCardShape.scrimStart, ContinueWatchingCardShape.mirrorLine)
        let run = 1 - ContinueWatchingCardShape.scrimStart
        let band = 1 - ContinueWatchingCardShape.mirrorLine
        XCTAssertGreaterThan(run, band * 1.5, "the ramp needs materially more distance than the band")
    }

    /// …but it still leaves the top half of the picture completely alone.
    func testScrimLeavesTheTopOfThePictureAlone() {
        XCTAssertGreaterThan(ContinueWatchingCardShape.scrimStart, 0.6)
    }

    /// Lighter than an ordinary card's, because the reflection's wash darkens the
    /// same region and the two compound.
    func testScrimIsLighterThanOnACardWithNoReflection() {
        XCTAssertLessThan(ContinueWatchingCardShape.scrimDepth, 0.78)
    }

    /// The logo sits between the picture's own centre and the card's. Centred on
    /// the picture alone it read as too high (the reflection beneath is still
    /// card the eye weighs); centred on the card it would land on the chrome.
    func testLogoSitsBetweenThePictureCentreAndTheCardCentre() {
        XCTAssertGreaterThan(
            ContinueWatchingCardShape.logoCenter,
            ContinueWatchingCardShape.mirrorLine / 2
        )
        XCTAssertLessThan(ContinueWatchingCardShape.logoCenter, 0.5)
    }

    /// Wherever it is centred, the logo stays inside the picture — it must never
    /// reach the mirror line and spill into its own reflection.
    ///
    /// Measured against the mirror line rather than the scrim's start: the scrim
    /// eases in from nothing, so its first stretch is imperceptible and overlapping
    /// it costs the logo nothing. Reaching the reflection is the real failure.
    ///
    /// Checked at the **flexed** height, since `HeroLogoFit` lets a tall shape grow
    /// past its nominal box — that is the case that would actually collide.
    func testLogoStaysInsideThePictureEvenWhenTall() {
        let card = Self.card
        let box = ContinueWatchingCardShape.logoBox(
            cardWidth: card.width,
            stage: card.stage,
            edgeInset: Self.chipInset
        )
        let tallest = box.height * HeroLogoFit.heightFlex
        let foot = ContinueWatchingCardShape.logoCenter
            + (tallest / card.height) / 2
        let head = ContinueWatchingCardShape.logoCenter
            - (tallest / card.height) / 2
        XCTAssertLessThan(foot, ContinueWatchingCardShape.mirrorLine)
        XCTAssertGreaterThan(head, 0)
    }

    /// **A logo never crowds the card's side edges.**
    ///
    /// The one that bit: `HeroLogoFit` lets a wide wordmark flex to
    /// `widthFlex` past its nominal width, so a 78% budget was being *drawn* at
    /// 97% of the card and all but touching both edges. The cap has to be applied
    /// to the drawn width, not the budget.
    func testWidestLogoKeepsClearOfTheCardEdges() {
        let card = Self.card
        let box = ContinueWatchingCardShape.logoBox(
            cardWidth: card.width,
            stage: card.stage,
            edgeInset: Self.chipInset
        )
        let widest = box.width * HeroLogoFit.widthFlex
        let margin = (card.width - widest) / 2

        XCTAssertLessThanOrEqual(widest, card.width * 0.81, "drawn no wider than ~80% of the card")
        XCTAssertGreaterThanOrEqual(
            margin,
            Self.chipInset,
            "a logo must sit no closer to the edge than the chip's own chrome"
        )
    }

    /// The clearance tracks the chrome when the chrome grows. At a large text
    /// size the chip's inset grows, and a pure fraction of the card would not —
    /// so the floor is taken from the real inset.
    func testEdgeClearanceFollowsAnUnusuallyLargeChipInset() {
        let card = Self.card
        let hugeInset = card.width * 0.2
        let box = ContinueWatchingCardShape.logoBox(
            cardWidth: card.width,
            stage: card.stage,
            edgeInset: hugeInset
        )
        let widest = box.width * HeroLogoFit.widthFlex
        XCTAssertGreaterThanOrEqual((card.width - widest) / 2, hugeInset - 0.5)
    }

    /// Holding logos off the edges must not quietly shrink every logo: the width
    /// the clearance takes is given back in height, so the **area** `HeroLogoFit`
    /// sizes on is preserved and only the over-wide shapes give ground.
    func testEdgeClearancePreservesTheLogoAreaBudget() {
        let card = Self.card
        let box = ContinueWatchingCardShape.logoBox(
            cardWidth: card.width,
            stage: card.stage,
            edgeInset: Self.chipInset
        )
        let budget = (card.width * ContinueWatchingCardShape.logoWidthFraction)
            * (card.stage * ContinueWatchingCardShape.logoHeightFraction)
        let actual = box.width * box.height
        // Within a couple of percent by area — under 1% in linear terms.
        XCTAssertEqual(actual / budget, 1, accuracy: 0.03)
    }

    /// A narrower card than an ordinary landscape one: it grew taller to make
    /// room for its chrome, and height is what a rail spends.
    func testCardIsNarrowerThanAPlainLandscapeCard() {
        XCTAssertLessThan(ContinueWatchingCardShape.widthScale, 1)
        XCTAssertGreaterThan(ContinueWatchingCardShape.widthScale, 0.75)
    }

    /// The logo is bigger than on the flat 16:9 card this replaced (0.66 × 0.34 of
    /// it) — the point of the change, since these are read from ten feet away.
    ///
    /// Compared by **area**, because `HeroLogoFit` sizes every wordmark to cover a
    /// target area: the product of the two caps is what decides how large a logo
    /// looks, not either one alone. The new card is both smaller and a different
    /// shape, so comparing a single dimension would say nothing.
    func testLogoIsLargerThanTheFlatCardTreatment() {
        let flatWidth = PlozzTheme.Metrics.landscapeWidth
        let flatHeight = PlozzTheme.Metrics.landscapeHeight
        let width = flatWidth * ContinueWatchingCardShape.widthScale
        let cardHeight = width / ContinueWatchingCardShape.aspectRatio

        let was = (flatWidth * 0.66) * (flatHeight * 0.34)
        let now = (width * ContinueWatchingCardShape.logoWidthFraction)
            * (cardHeight
                * ContinueWatchingCardShape.mirrorLine
                * ContinueWatchingCardShape.logoHeightFraction)

        XCTAssertGreaterThan(now, was)
    }

    /// **Four cards fit on a standard TV, with a fifth peeking.**
    ///
    /// This is the goal the card's width was actually chosen for, so it is
    /// asserted rather than left to the eye. The previous width ran the fourth
    /// card off the right edge, which made the row read as three-and-a-bit and
    /// look like it ended there — a rail has to show that it continues.
    ///
    /// Modelled on the real rail: a 1920pt screen, tvOS's ~60pt leading safe
    /// area, cards laid in an `HStack` at `cardSpacing`, each occupying its full
    /// glass slot (artwork + `cardInset` either side).
    func testFourCardsAndAPeekFitOnAStandardTV() {
        let screen: CGFloat = 1920
        let leadingSafeArea: CGFloat = 60
        let metrics = PlozzMetrics(density: .standard, dynamicTypeSize: .large)
        let slot = metrics.cardSlotWidth(
            for: .landscape,
            cardStyle: .framed,
            showsSeriesArtwork: true
        )
        let pitch = slot + metrics.cardSpacing

        let fourthCardTrailingEdge = leadingSafeArea + 3 * pitch + slot
        XCTAssertLessThanOrEqual(
            fourthCardTrailingEdge,
            screen,
            "the fourth card must fit fully on screen"
        )

        let fifthCardLeadingEdge = leadingSafeArea + 4 * pitch
        let peek = screen - fifthCardLeadingEdge
        XCTAssertGreaterThan(peek, slot * 0.15, "the fifth card must visibly peek")
        XCTAssertLessThan(peek, slot * 0.5, "a half-shown fifth card is not a peek")
    }

    /// A very wide wordmark is the one shape clamped by width rather than by
    /// area, so it is the one that gives ground when the card shrinks — every
    /// other shape keeps its size. That is the intended trade, so pin it: the
    /// width cap must stay meaningfully below the card's full width, or a wide
    /// logo would run edge to edge.
    func testWideLogosAreTheOnesConstrainedByWidth() {
        XCTAssertLessThan(ContinueWatchingCardShape.logoWidthFraction, 0.9)
        // …while the area budget is generous enough that ordinary shapes are
        // decided by area instead.
        let budget = ContinueWatchingCardShape.logoWidthFraction
            * ContinueWatchingCardShape.logoHeightFraction
        XCTAssertGreaterThan(budget, 0.35)
    }

    /// A flat dim over the whole card, so the logo and chip sit on the picture
    /// rather than compete with it — and deliberately flat, since a second shaped
    /// gradient over the same pixels gives the eye an edge to find.
    /// Reads as darker than an ordinary card's plain dim, since it is also doing
    /// the work of making a wordmark legible over arbitrary artwork.
    func testArtworkCarriesAnEvenDim() {
        XCTAssertGreaterThan(ContinueWatchingCardShape.artworkDim, 0.2)
        // Light enough that artwork is still artwork.
        XCTAssertLessThan(ContinueWatchingCardShape.artworkDim, 0.45)
    }

    /// The reflection has to over-cover its band on every side.
    ///
    /// This is what lets the band be backed by *clear* rather than by black. A
    /// black backing was the cause of a dark hairline at the seam: wherever a
    /// scale transform antialiased the mirrored image's own edge row, the black
    /// behind it blended through — invisible on dark art, an obvious dark line on
    /// pale art. With nothing behind but the picture the band overlaps, a
    /// softened edge resolves to the picture's own colour instead. That argument
    /// only holds while the mirrored image genuinely covers the whole band.
    func testReflectionOverCoversItsOwnBand() {
        let card = ExtendedArtworkGeometry(
            slot: CGSize(width: 432, height: 313),
            artworkAspectRatio: 16.0 / 9.0,
            sideCrop: PlozzTheme.Metrics.continueWatchingArtworkSideCrop
        )
        // Horizontally: the mirrored copy is rendered at the same over-wide size
        // as the picture, so it reaches past both edges of the card.
        XCTAssertGreaterThanOrEqual(card.renderedWidth, 432)
        // Vertically: the copy is a full picture-height tall, so starting it at
        // the seam it runs well past the foot of a band this shallow.
        XCTAssertGreaterThan(card.pictureHeight, card.reflectionHeight)
    }
}

/// The easing behind every ramp drawn over artwork.
///
/// This exists because of a real defect: the reflection's wash used to begin at
/// 0.15 black while the picture above it was at 0, putting a 15-point step into a
/// single row. On dark art nobody saw it; on bright art — sand, fire, a pale grey
/// poster — it was a hard line straight across the card. The rules below are the
/// ones that stop that happening again.
final class ArtworkGradientRampTests: XCTestCase {

    /// A ramp must begin at *exactly* nothing. Anything else is a step.
    func testRampStartsAtExactlyZero() {
        let stops = ArtworkGradientRamp.stops(peak: 0.55, from: 0, to: 1)
        XCTAssertEqual(ArtworkGradientRamp.eased(0, bias: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(stops.first?.location, 0)
    }

    func testRampReachesItsPeakAtTheEnd() {
        XCTAssertEqual(ArtworkGradientRamp.eased(1, bias: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(ArtworkGradientRamp.stops(peak: 0.55, from: 0.3, to: 1).last?.location, 1)
    }

    /// Eased at both ends: the rate of change starts and finishes at nothing, so
    /// neither end of the ramp draws an edge (a Mach band) across the artwork.
    func testRampEasesInAndOutRatherThanRunningStraight() {
        let f = { ArtworkGradientRamp.eased($0, bias: 1) }
        // First tenth moves less than a straight line would; so does the last.
        XCTAssertLessThan(f(0.1), 0.1)
        XCTAssertGreaterThan(f(0.9), 0.9)
        // A straight line would sit exactly on t; the curve only meets it midway.
        XCTAssertEqual(f(0.5), 0.5, accuracy: 0.0001)
    }

    func testRampRisesMonotonically() {
        var previous: CGFloat = -1
        for step in 0...20 {
            let value = ArtworkGradientRamp.eased(CGFloat(step) / 20, bias: 1.4)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testRampIsClampedOutsideItsRange() {
        XCTAssertEqual(ArtworkGradientRamp.eased(-3, bias: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(ArtworkGradientRamp.eased(4, bias: 1), 1, accuracy: 0.0001)
    }

    /// A bias above 1 holds the ramp lighter for longer — what a reflection wants,
    /// since it is strongest where it meets the picture.
    func testBiasHoldsTheRampLighterForLonger() {
        for t in [CGFloat(0.2), 0.4, 0.6, 0.8] {
            XCTAssertLessThan(
                ArtworkGradientRamp.eased(t, bias: 1.4),
                ArtworkGradientRamp.eased(t, bias: 1)
            )
        }
        // …without ever changing where it starts or ends.
        XCTAssertEqual(ArtworkGradientRamp.eased(0, bias: 1.4), 0, accuracy: 0.0001)
        XCTAssertEqual(ArtworkGradientRamp.eased(1, bias: 1.4), 1, accuracy: 0.0001)
    }

    func testStopsAreOrderedAndInsideTheirSpan() {
        let stops = ArtworkGradientRamp.stops(peak: 0.78, from: 0.8, to: 1)
        XCTAssertGreaterThan(stops.count, 2, "a two-stop ramp is the straight line this replaces")
        for (earlier, later) in zip(stops, stops.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.location, later.location)
        }
        XCTAssertEqual(stops.first?.location, 0.8)
        XCTAssertEqual(stops.last?.location, 1)
    }

    /// The top-anchored form is the same curve upside down: deepest at the edge,
    /// gone by the end.
    func testFadingStopsRunFromPeakToNothing() {
        let stops = ArtworkGradientRamp.fadingStops(peak: 0.5, from: 0, to: 0.34)
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.last?.location, 0.34)
        for (earlier, later) in zip(stops, stops.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.location, later.location)
        }
    }

    /// A degenerate span can't produce an out-of-order or empty gradient.
    func testDegenerateSpanStillProducesAUsableStop() {
        XCTAssertEqual(ArtworkGradientRamp.stops(peak: 0.5, from: 0.6, to: 0.6).count, 1)
        XCTAssertEqual(ArtworkGradientRamp.fadingStops(peak: 0.5, from: 1, to: 0).count, 1)
    }

    /// The compounded result of the two ramps that overlap on the reflection band
    /// — the chip's scrim, which runs from up in the picture, and the reflection's
    /// own wash, which starts at the mirror line.
    ///
    /// The wash is the one that must start at nothing: it is a separate layer laid
    /// only over the reflection, so any value it starts with becomes a step at the
    /// seam. The scrim is one continuous gradient across the whole card, so it
    /// passes through the mirror line without creating an edge however dark it is
    /// there.
    func testWashAndScrimCompoundSmoothlyRatherThanToNearBlack() {
        let washPeak: CGFloat = 0.34
        let scrimPeak = ContinueWatchingCardShape.scrimDepth
        let mirror = ContinueWatchingCardShape.mirrorLine
        let scrimStart = ContinueWatchingCardShape.scrimStart

        func scrim(atCard y: CGFloat) -> CGFloat {
            scrimPeak * ArtworkGradientRamp.eased((y - scrimStart) / (1 - scrimStart), bias: 1)
        }
        func combined(atCard y: CGFloat) -> CGFloat {
            let wash = y < mirror
                ? 0
                : washPeak * ArtworkGradientRamp.eased((y - mirror) / (1 - mirror), bias: 1.4)
            return 1 - (1 - wash) * (1 - scrim(atCard: y))
        }

        // The wash contributes exactly nothing at the seam — this is the fix for
        // the hard line, and it is the only part that can put a step there.
        XCTAssertEqual(
            washPeak * ArtworkGradientRamp.eased(0, bias: 1.4), 0, accuracy: 0.0001
        )
        // Deep enough at the foot for the chip, and clearly short of the
        // near-black the two reached when both ran to full depth (0.978).
        XCTAssertGreaterThan(combined(atCard: 1), 0.75)
        XCTAssertLessThan(combined(atCard: 1), 0.85)
        // Untouched across the top of the card, where the logo lives.
        XCTAssertEqual(combined(atCard: 0.5), 0, accuracy: 0.001)
        // …and strictly increasing throughout, so there is no edge anywhere.
        var previous: CGFloat = -1
        for step in 0...40 {
            let value = combined(atCard: CGFloat(step) / 40)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }
}

#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// A Continue Watching card writes its text *inside* the artwork — "S1, E12 ·
/// 17m", on one line, next to a play glyph and a progress bar — instead of in a
/// caption underneath that could wrap or grow. That makes it the one card whose
/// width has to answer to Dynamic Type: the label tracks the reader's chosen
/// size, and a card sized only by display density does not, so turning text up
/// truncated the episode being named down to "S1, E1 · 4…".
final class ContinueWatchingDynamicTypeTests: XCTestCase {

    private func width(_ size: DynamicTypeSize) -> CGFloat {
        PlozzMetrics(density: .standard, dynamicTypeSize: size).continueWatchingWidth
    }

    /// Nothing changes until someone actually turns text up.
    func testDefaultTextSizeIsUnchanged() {
        let metrics = PlozzMetrics(density: .standard, dynamicTypeSize: .large)
        XCTAssertEqual(
            metrics.continueWatchingWidth,
            (metrics.landscapeWidth * ContinueWatchingCardShape.widthScale).rounded(),
            accuracy: 1
        )
    }

    /// Bigger text buys a wider card, which is the whole fix.
    func testLargerTextWidensTheCard() {
        XCTAssertGreaterThan(width(.accessibility1), width(.large))
    }

    /// …and it never shrinks as text grows.
    func testWidthNeverShrinksAsTextGrows() {
        let sizes: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
        ]
        for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
            XCTAssertLessThanOrEqual(
                width(smaller),
                width(larger),
                "\(larger) must not be narrower than \(smaller)"
            )
        }
    }

    /// Capped, or an accessibility size would hand back a card wider than the
    /// phone it has to sit on. Past the cap the label scales itself down instead.
    func testWidthIsCappedAtTheAccessibilitySizes() {
        let base = width(.large)
        XCTAssertLessThanOrEqual(width(.accessibility5), base * 1.6 + 1)
    }

    /// The bar grows once the text around it does — the original complaint was
    /// that it looked proportionally short beside very large type.
    func testProgressBarGrowsWithLargeTextOnly() {
        let base = PlozzMetrics(density: .standard, dynamicTypeSize: .large)
        let large = PlozzMetrics(density: .standard, dynamicTypeSize: .accessibility1)
        XCTAssertGreaterThan(large.resumeChipBarHeight, base.resumeChipBarHeight)
    }

    /// The bar's width ceiling may grow with the text, but only because the bar
    /// is *flexible* where it shares a line with a label: it is a maximum the bar
    /// may reach, never a width it insists on. A rigid bar that grew this way is
    /// what truncated "S4, E1 · 44m" down to "S4, E1 ·…".
    func testProgressBarWidthCeilingGrowsButStaysDamped() {
        let base = PlozzMetrics(density: .standard, dynamicTypeSize: .large)
        let large = PlozzMetrics(density: .standard, dynamicTypeSize: .accessibility5)
        XCTAssertGreaterThan(large.resumeChipBarWidth, base.resumeChipBarWidth)
        let fontGrowth = large.resumeChipFontSize / base.resumeChipFontSize
        let widthGrowth = large.resumeChipBarWidth / base.resumeChipBarWidth
        XCTAssertLessThan(widthGrowth, fontGrowth, "the bar must grow more slowly than the text")
    }

    /// Height growth is damped and capped: it should nod to the text, not track
    /// it, or the gauge becomes the loudest thing on the card.
    func testProgressBarHeightGrowthIsDampedAndCapped() {
        let base = PlozzMetrics(density: .standard, dynamicTypeSize: .large)
        let biggest = PlozzMetrics(density: .standard, dynamicTypeSize: .accessibility5)
        let fontGrowth = biggest.resumeChipFontSize / base.resumeChipFontSize
        let barGrowth = biggest.resumeChipBarHeight / base.resumeChipBarHeight
        XCTAssertGreaterThan(barGrowth, 1)
        XCTAssertLessThan(barGrowth, fontGrowth, "the bar must grow more slowly than the text")
        XCTAssertLessThanOrEqual(barGrowth, 1.5 + 0.01)
    }

    /// **The tuned sizes are untouched at the default text size.**
    ///
    /// This is the guarantee that matters: the bar was never wrong as drawn, it
    /// only looked short once the text around it had grown. An earlier attempt
    /// raised the base height as well, which made the bar visibly taller for
    /// everyone at normal text — a regression for the many to fix something only
    /// the few saw. Growth is allowed; a new baseline is not.
    func testDefaultTextSizeKeepsTheTunedBarExactly() {
        let metrics = PlozzMetrics(density: .standard, dynamicTypeSize: .large)
        XCTAssertEqual(metrics.resumeChipBarWidth, PlozzTheme.Metrics.resumeChipBarWidth)
        XCTAssertEqual(metrics.resumeChipBarHeight, PlozzTheme.Metrics.resumeChipBarHeight)
        // The hero's tuned tvOS height, which the heroes used to hardcode.
        XCTAssertEqual(metrics.heroProgressBarHeight, 10)
    }

    /// …and below the default it never shrinks either: a small-text reader gets
    /// the same tuned bar, not a thinner one.
    func testSmallerTextDoesNotShrinkTheBar() {
        let base = PlozzMetrics(density: .standard, dynamicTypeSize: .large)
        for size in [DynamicTypeSize.xSmall, .small, .medium] {
            let metrics = PlozzMetrics(density: .standard, dynamicTypeSize: size)
            XCTAssertEqual(metrics.resumeChipBarHeight, base.resumeChipBarHeight)
            XCTAssertEqual(metrics.resumeChipBarWidth, base.resumeChipBarWidth)
            XCTAssertEqual(metrics.heroProgressBarHeight, base.heroProgressBarHeight)
        }
    }

    /// The hero Play button's gauge adapts too, on the same damped curve.
    ///
    /// It was a fixed height under a button whose label doubles with the reader's
    /// text size, so at large sizes it read as a hairline under a very large
    /// control.
    func testHeroPlayButtonBarAdaptsToText() {
        let base = PlozzMetrics(density: .standard, dynamicTypeSize: .large)
        let large = PlozzMetrics(density: .standard, dynamicTypeSize: .accessibility1)
        XCTAssertGreaterThan(large.heroProgressBarHeight, base.heroProgressBarHeight)
        // Damped, like the chip's — it must not track the type curve 1:1.
        let fontGrowth = large.resumeChipFontSize / base.resumeChipFontSize
        let barGrowth = large.heroProgressBarHeight / base.heroProgressBarHeight
        XCTAssertLessThan(barGrowth, fontGrowth)
    }

    /// A hero button is a much bigger control carrying much bigger type, so its
    /// gauge is heavier than the one on a card chip at every size.
    func testHeroBarIsHeavierThanTheCardChipBar() {
        for size in [DynamicTypeSize.large, .accessibility1, .accessibility5] {
            let metrics = PlozzMetrics(density: .standard, dynamicTypeSize: size)
            XCTAssertGreaterThanOrEqual(
                metrics.heroProgressBarHeight,
                metrics.resumeChipBarHeight,
                "hero bar should not be lighter than the card chip's at \(size)"
            )
        }
    }

    /// Never a sub-pixel hairline, whatever the density and text size combine to.
    func testProgressBarIsNeverAHairline() {
        for density in [UIDensity.compact, .standard, .extraLarge] {
            for size in [DynamicTypeSize.xSmall, .large, .accessibility5] {
                let metrics = PlozzMetrics(density: density, dynamicTypeSize: size)
                XCTAssertGreaterThanOrEqual(metrics.resumeChipBarHeight, 3)
            }
        }
    }

    /// The rail's slot has to follow the card, or the pitch stops matching what
    /// is drawn and cards overlap or drift apart.
    func testRailSlotFollowsTheCardWidth() {
        let metrics = PlozzMetrics(density: .standard, dynamicTypeSize: .accessibility1)
        let slot = metrics.cardSlotWidth(
            for: .landscape,
            cardStyle: .framed,
            showsSeriesArtwork: true
        )
        XCTAssertEqual(slot, metrics.continueWatchingWidth + metrics.cardInset * 2, accuracy: 0.5)
        // …and an ordinary landscape card is left alone by all of this.
        XCTAssertEqual(
            metrics.cardSlotWidth(for: .landscape, cardStyle: .framed),
            metrics.landscapeCardSlotWidth,
            accuracy: 0.5
        )
    }
}
#endif
