#if canImport(SwiftUI)
import SwiftUI

/// How a wide picture is laid into a slot that is **taller** than the picture.
///
/// Continue Watching cards are taller than the 16:9 art they carry so their
/// chrome — play glyph, progress bar, "S1, E12 · 17m" — can sit *below* the
/// picture instead of on top of the subject. This works out the two bands that
/// split: how much of the card the picture itself occupies, and how much is left
/// underneath for ``ExtendedArtworkFill`` to fill.
///
/// Split out from the view so the numbers are unit-testable without rendering.
public struct ExtendedArtworkGeometry: Equatable, Sendable {
    /// Height of the picture band — the artwork at its own aspect ratio.
    public let pictureHeight: CGFloat
    /// Height of the band below it, filled with a mirrored continuation.
    public let reflectionHeight: CGFloat
    /// Width the artwork is *rendered* at before the slot clips it. Wider than
    /// the slot whenever a side crop is asked for; that overhang is what gets
    /// trimmed, and it is also what makes the picture stand taller in the card.
    public let renderedWidth: CGFloat

    /// - Parameters:
    ///   - slot: the space the card gave the artwork.
    ///   - artworkAspectRatio: the shape the picture is drawn at (width ÷ height).
    ///     16:9 for backdrop art; anything the source isn't gets centre-cropped
    ///     into it, exactly as a plain fill would.
    ///   - sideCrop: fraction of the width trimmed from **each** side.
    public init(slot: CGSize, artworkAspectRatio: CGFloat, sideCrop: CGFloat) {
        let width = max(0, slot.width)
        let height = max(0, slot.height)
        let aspect = artworkAspectRatio > 0 ? artworkAspectRatio : 16.0 / 9.0
        // A crop of half the width or more would be a different picture, not a
        // trim, so the visible fraction is floored well before that.
        let visible = min(1, max(0.5, 1 - 2 * max(0, sideCrop)))
        renderedWidth = width / visible
        // Never taller than the slot: with no room to spare the picture simply
        // fills it and there is no reflection, which is what a 16:9 slot (a
        // thumbnail-style card) gets.
        pictureHeight = min(height, renderedWidth / aspect)
        reflectionHeight = max(0, height - pictureHeight)
    }

    /// Where the picture ends, as a fraction of the slot's height — i.e. where
    /// the reflection begins. Chrome scrims ramp from here so they darken the
    /// reflection they sit on rather than half the picture above it.
    public var reflectionStart: CGFloat {
        let total = pictureHeight + reflectionHeight
        guard total > 0 else { return 1 }
        return pictureHeight / total
    }
}

/// Artwork drawn into a slot taller than itself, with the shortfall filled by a
/// **mirrored continuation of the picture's own bottom edge** rather than by a
/// blurred blow-up of the whole image.
///
/// The picture is never squashed and never letterboxed: it keeps its aspect
/// ratio, gives up an unnoticeable sliver from each side (see
/// ``PlozzTheme/Metrics/continueWatchingArtworkSideCrop``), and the band beneath
/// it is the same image flipped and faded out — the way a photograph sitting on
/// a polished surface reflects into it.
///
/// A blurred fill (the obvious alternative, and what the platform's own app
/// does) has to smear the picture's *whole* lower half to cover the same band,
/// so the thing it extends is also the thing it destroys. A mirror only ever
/// touches pixels the picture was going to end on anyway, so at a glance the
/// card reads as one uninterrupted image with a soft bottom.
///
/// Takes the picture as a ready-made view rather than loading one, so the card
/// and its reflection are two layers over ONE decode (see ``FallbackAsyncImage``,
/// whose `content` hands over the resolved `Image`) — and so the Settings
/// preview can render a fabricated picture through this exact same code path
/// instead of imitating it.
public struct ExtendedArtworkFill<Picture: View>: View {
    private let picture: Picture
    private let artworkAspectRatio: CGFloat
    private let sideCrop: CGFloat

    /// - Parameters:
    ///   - picture: the image to lay in, sized by this view. Callers with a
    ///     resolved `Image` should use ``init(image:artworkAspectRatio:sideCrop:)``.
    ///   - artworkAspectRatio: the shape the picture is drawn at (width ÷ height).
    ///   - sideCrop: fraction of the width trimmed from **each** side.
    public init(
        picture: Picture,
        artworkAspectRatio: CGFloat = 16.0 / 9.0,
        sideCrop: CGFloat = PlozzTheme.Metrics.continueWatchingArtworkSideCrop
    ) {
        self.picture = picture
        self.artworkAspectRatio = artworkAspectRatio
        self.sideCrop = sideCrop
    }

    public var body: some View {
        GeometryReader { geo in
            let geometry = ExtendedArtworkGeometry(
                slot: geo.size,
                artworkAspectRatio: artworkAspectRatio,
                sideCrop: sideCrop
            )
            // ONE clip, on the outside, and none within.
            //
            // Every `.clipped()` is a rasterisation boundary, and a boundary is
            // resampled independently when an ancestor scales the card on focus.
            // Two of them on the same line — the picture's bottom and the
            // reflection's top — meant that at rest they landed on whole pixels
            // and looked perfect, while any scale resampled both and let a
            // hairline show between them. Overlapping the layers alone did not
            // fix it, because the edges were still there to be resampled; they
            // have to not exist. Nothing here needs its own clip: the picture may
            // overrun into the band because the opaque reflection covers it, and
            // the reflection may overrun past the card because this clip cuts it.
            ZStack(alignment: .top) {
                sizedPicture(geometry)
                if geometry.reflectionHeight > 0 {
                    reflection(geometry, width: geo.size.width)
                        .offset(y: geometry.pictureHeight - ExtendedArtworkWash.seamOverlap)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
    }

    /// The artwork at its own shape, rendered wide enough that the slot trims a
    /// sliver from each side.
    private func sizedPicture(_ geometry: ExtendedArtworkGeometry) -> some View {
        picture
            .frame(width: geometry.renderedWidth, height: geometry.pictureHeight)
    }

    /// The band under the picture: the same image flipped vertically, so its top
    /// row is (all but a couple of points of) the picture's last row and the two
    /// meet with no seam of their own, then washed out downward into the black it
    /// stands on.
    ///
    /// Left deliberately **unblurred**. A blur would be a full-band GPU filter on
    /// every card of a rail that scrolls, and it would also have to sample the
    /// transparency just past the mirror line, which puts a bright hairline along
    /// the exact edge the effect depends on being invisible.
    private func reflection(_ geometry: ExtendedArtworkGeometry, width: CGFloat) -> some View {
        // Clear, NOT black. A black base is what made the hairline dark — and so
        // worst on pale artwork, where it had the most to contrast with. The
        // mirrored image is opaque and over-covers this band on every side, so
        // the base is only ever a sizing box for the gradient; but any row where
        // the image's own edge is antialiased by a scale transform would blend
        // through to whatever sits behind it. Behind it is now the picture this
        // band overlaps, whose pixels are the same ones — so a softened edge
        // resolves to the right colour instead of to black.
        Color.clear
            .frame(width: width, height: geometry.reflectionHeight + ExtendedArtworkWash.seamOverlap)
            .overlay(alignment: .top) {
                sizedPicture(geometry)
                    .scaleEffect(x: 1, y: -1)
            }
            .overlay {
                LinearGradient(
                    gradient: ExtendedArtworkWash.gradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }
}

extension ExtendedArtworkFill where Picture == ArtworkFillImage {
    public init(
        image: Image,
        artworkAspectRatio: CGFloat = 16.0 / 9.0,
        sideCrop: CGFloat = PlozzTheme.Metrics.continueWatchingArtworkSideCrop
    ) {
        self.init(
            picture: ArtworkFillImage(image),
            artworkAspectRatio: artworkAspectRatio,
            sideCrop: sideCrop
        )
    }
}

/// The one description of a Continue Watching card's shape, so the card, the
/// logo laid over it, the scrim under its chrome and the Settings preview can't
/// drift apart. Everything here is a fraction of the card, so it holds at any
/// display density.
public enum ContinueWatchingCardShape {
    /// Width ÷ height of the whole card, derived from how much reflection it
    /// should show (``PlozzTheme/Metrics/continueWatchingReflectionShare``)
    /// rather than picked as a magic number.
    ///
    /// The picture's height is fixed by the card's width — it is 16:9 art, scaled
    /// up by whatever the side trim leaves — so the card's height is that plus the
    /// band, and the ratio follows.
    ///
    /// Stored rather than computed: it is read inside per-card `GeometryReader`
    /// bodies on a rail that scrolls, so it must not rebuild anything.
    public static let aspectRatio: CGFloat = {
        let usableWidth = 1 - 2 * PlozzTheme.Metrics.continueWatchingArtworkSideCrop
        let pictureHeight = usableWidth <= 0 ? 1 : (1 / usableWidth) * 9 / 16
        return 1 / (pictureHeight * (1 + PlozzTheme.Metrics.continueWatchingReflectionShare))
    }()

    /// How wide this card is relative to an ordinary landscape card.
    ///
    /// Chosen to fit a whole rail rather than picked as a look: at 1920pt — a
    /// standard TV, at the default text size — this puts **four cards on screen
    /// with about a third of a fifth showing**, which is what tells the viewer
    /// the row scrolls. The previous value ran the fourth card off the edge, so
    /// the row read as three-and-a-bit and looked like it ended there.
    ///
    /// Below 1 also because the card grew *taller* to make room for its chrome,
    /// and height is what a rail spends: at full width it would stand a third
    /// taller than the row it replaced.
    ///
    /// Only the card scales with this. The chip's type, play glyph and progress
    /// bar are absolute sizes from ``PlozzMetrics`` and the logo is sized to hold
    /// its own area (see ``logoWidthFraction``), so shrinking the card gives back
    /// rail space rather than quietly shrinking everything written on it.
    public static let widthScale: CGFloat = 0.80

    /// Bands of a card of this shape carrying 16:9 art.
    public static let geometry = ExtendedArtworkGeometry(
        // Pure ratios: a slot one unit tall describes the shape completely.
        slot: CGSize(width: aspectRatio, height: 1),
        artworkAspectRatio: 16.0 / 9.0,
        sideCrop: PlozzTheme.Metrics.continueWatchingArtworkSideCrop
    )

    /// Where the picture ends and its reflection begins, as a fraction of the
    /// card's height.
    public static let mirrorLine: CGFloat = geometry.reflectionStart

    /// Where the chrome's legibility scrim starts darkening, as a fraction of the
    /// card's height.
    ///
    /// Well **above** the mirror line, and deliberately so. Confining the ramp to
    /// the reflection band alone meant all of the darkening had to happen inside
    /// the bottom sixth of the card, which is a short distance to travel: it
    /// arrived fast and piled up near-black at the foot. Starting it up in the
    /// picture gives the ramp three times the distance, so it can reach a lighter
    /// final depth (see ``scrimDepth``) and still bed the chip's text. Because it
    /// eases in from zero slope (``ArtworkGradientRamp``) the first third of that
    /// distance is too slight to see, so the picture reads as untouched anyway.
    public static let scrimStart: CGFloat = 0.66

    /// How dark that scrim gets at the very foot.
    ///
    /// Lighter than the 0.78 an ordinary card uses, because here it compounds
    /// with the reflection's own wash — together they land near 0.79. Enough to
    /// read the chip against without the band going flat black and taking the
    /// reflection with it.
    public static let scrimDepth: CGFloat = 0.68

    /// Fraction of the card's width the logo may occupy.
    ///
    /// This and ``logoHeightFraction`` are a *budget*, not a box: `HeroLogoFit`
    /// sizes every wordmark to cover the same **area**, so their product is what
    /// decides how big a logo looks, and either dimension may flex if the shape
    /// needs it.
    ///
    /// Both were raised when the card shrank, so that budget stays roughly where
    /// it was and an ordinary logo is the size it always was on a smaller card.
    /// Width was raised by *less* than height on purpose: a very wide wordmark is
    /// the one shape clamped by width rather than by area, so it — and only it —
    /// comes down with the card, which is the right shape to give ground.
    public static let logoWidthFraction: CGFloat = 0.78

    /// Fraction of the *picture band* the logo may occupy vertically. Measured
    /// against the picture rather than the card so the logo is sized against the
    /// image and the chrome band underneath stays its own space.
    public static let logoHeightFraction: CGFloat = 0.48

    /// Least clearance between the logo and the card's side edges, as a fraction
    /// of the card's width — so a logo is never closer to the edge than the
    /// chip's play glyph is, and in practice further.
    ///
    /// 10% a side, i.e. a logo is drawn no wider than **80% of the card**. This
    /// is a cap on what is actually DRAWN, which is not the same as the width
    /// budget above: `HeroLogoFit` lets a wide shape flex to ``HeroLogoFit/widthFlex``
    /// past its nominal width, so a 78% budget was being drawn at 97% of the card
    /// and very nearly touching both edges.
    ///
    /// It also evens out how heavy logos look. Fitting by area already gives every
    /// wordmark the same coverage, but a wide one spanning the full card still
    /// reads as much heavier than a compact one of identical area — spanning the
    /// frame is its own kind of emphasis. Holding every logo off the edges takes
    /// that away.
    public static let logoEdgeInsetFraction: CGFloat = 0.10

    /// Ceiling on the logo's nominal height, as a fraction of the picture band.
    /// Bounded so that a *tall* logo taking ``HeroLogoFit/heightFlex`` past it
    /// still cannot reach the mirror line and spill into its own reflection.
    public static let logoMaxHeightFraction: CGFloat = 0.58

    /// The nominal box a Continue Watching logo is fitted into.
    ///
    /// Resolves the width budget against the edge clearance, then gives back in
    /// height whatever the clearance took in width, so the logo's **area** — what
    /// `HeroLogoFit` actually sizes on — is preserved. The effect is that only the
    /// shapes that are genuinely too wide give ground; every other logo is the
    /// size it would have been.
    ///
    /// - Parameter edgeInset: the chrome's own inset from the card edge, in
    ///   points. Taken as a floor so the logo tracks it at large text sizes, where
    ///   the chip's inset grows but a pure fraction would not.
    public static func logoBox(cardWidth: CGFloat, stage: CGFloat, edgeInset: CGFloat) -> CGSize {
        let budgetWidth = cardWidth * logoWidthFraction
        let budgetHeight = stage * logoHeightFraction
        let margin = max(cardWidth * logoEdgeInsetFraction, edgeInset)
        let drawnCeiling = max(1, cardWidth - 2 * margin)
        let width = max(1, min(budgetWidth, drawnCeiling / HeroLogoFit.widthFlex))
        let height = min(stage * logoMaxHeightFraction, budgetWidth * budgetHeight / width)
        return CGSize(width: width, height: max(1, height))
    }

    /// Where the logo's centre sits, as a fraction of the CARD's height.
    ///
    /// Below the picture band's own centre (`mirrorLine / 2`, ≈0.41) and above
    /// the card's (0.5). Centring on the picture alone reads as too high, because
    /// the reflection beneath is still part of the card the eye is weighing; but
    /// centring on the whole card pushes the logo down onto the chrome. Sitting
    /// between the two lands it where a viewer looks for a wordmark.
    public static let logoCenter: CGFloat = 0.455

    /// A flat dim laid over the whole card, picture and reflection alike.
    ///
    /// Not a legibility scrim — the chip has its own, and it is shaped. This is
    /// even, and its job is to take the top off artwork that would otherwise
    /// compete with what is written on it, so the logo and the chip read as
    /// sitting *on* the card rather than fighting it. Flat on purpose: anything
    /// with a shape to it would be a second gradient over the same pixels, and
    /// the eye finds the edge where two gradients disagree.
    public static let artworkDim: CGFloat = 0.33
}

/// The reflection's own constants, and the gradient built from them.
///
/// A file-level enum because ``ExtendedArtworkFill`` is generic, and a generic
/// type can hold no static stored properties — which is exactly what the
/// prebuilt gradient below has to be.
private enum ExtendedArtworkWash {
    /// How dark the reflection gets at the foot of the card.
    ///
    /// It starts at **exactly zero** at the mirror line, which is the whole trick:
    /// the reflection's top row already *is* the picture's last row, so with no
    /// darkening applied there the two are the same pixels and the seam cannot be
    /// seen at all. Beginning even slightly darker — an earlier version started at
    /// 0.15 — puts a step of that size into a single row, which is invisible on
    /// dark art and an obvious hard line across bright art (sand, fire, a pale
    /// grey poster). Whatever this ramp does lower down, it has to start at zero.
    ///
    /// The peak is modest because it is not working alone: the chip's own scrim
    /// (``MediaArtworkChromeScrim``) darkens the same band, and the two compound.
    static let footWash: CGFloat = 0.34
    /// Holds the reflection near full strength just under the picture, then lets
    /// it fall away. A reflection is brightest where it meets the thing being
    /// reflected; easing it symmetrically would dim exactly the part that makes
    /// it read as a reflection rather than a fade to black.
    static let washBias: CGFloat = 1.4
    /// How far the reflection is drawn up *behind* the picture's bottom edge.
    ///
    /// Two layers whose edges land on the same line are fine at rest and split
    /// open the moment the card is scaled: a focused card's edges no longer fall
    /// on whole pixels, so both get antialiased and whatever is behind shows
    /// through as a hairline. Overlapping them means the picture's edge is covered
    /// by opaque pixels rather than meeting another edge.
    ///
    /// The cost is that the reflection is off by this much — it shows the row it
    /// would have shown two points lower. Adjacent rows of a photograph are
    /// indistinguishable, so this costs nothing.
    static let seamOverlap: CGFloat = 2

    /// Built once. Every input is a constant, so rebuilding the ramp inside
    /// `body` would only mean allocating the same eight stops again for every
    /// card on every pass, on a rail that scrolls.
    static let gradient = Gradient(
        stops: ArtworkGradientRamp.stops(
            peak: footWash,
            from: 0,
            to: 1,
            bias: washBias
        )
    )
}

/// A smooth opacity ramp, expressed as gradient stops.
///
/// A two-stop `LinearGradient` changes at a constant rate, so at each end the
/// rate jumps from nothing to something within a single row. The eye reads that
/// discontinuity as an edge — a Mach band — which is exactly the "harsh line"
/// a scrim or a reflection wash must not have. Sampling an eased curve into
/// several stops removes both kinks, so the ramp begins and ends invisibly.
enum ArtworkGradientRamp {
    /// Smoothstep: starts and finishes with zero slope, so a ramp built from it
    /// has no visible beginning or end.
    static func eased(_ t: CGFloat, bias: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        let s = clamped * clamped * (3 - 2 * clamped)
        return bias == 1 ? s : pow(s, bias)
    }

    /// Stops ramping `.clear` → `color` at `peak` opacity, across `start...end`
    /// of the gradient's span.
    ///
    /// - Parameter bias: above 1 holds the ramp near zero for longer before it
    ///   falls away. A reflection wants that: it is strongest where it meets the
    ///   picture and fades with distance, so easing it symmetrically would dim
    ///   the very part that makes it read as a reflection at all.
    static func stops(
        peak: CGFloat,
        from start: CGFloat,
        to end: CGFloat,
        bias: CGFloat = 1,
        steps: Int = 7
    ) -> [Gradient.Stop] {
        guard steps > 0, end > start else {
            return [.init(color: .black.opacity(peak), location: min(1, max(0, end)))]
        }
        return (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            return Gradient.Stop(
                color: .black.opacity(peak * eased(t, bias: bias)),
                location: start + (end - start) * t
            )
        }
    }

    /// The same ramp the other way up: `peak` at `start`, easing away to nothing
    /// by `end`. For a scrim anchored to the TOP edge, where the darkening is
    /// deepest at the edge and has to disappear on its way inward.
    static func fadingStops(
        peak: CGFloat,
        from start: CGFloat,
        to end: CGFloat,
        steps: Int = 7
    ) -> [Gradient.Stop] {
        guard steps > 0, end > start else {
            return [.init(color: .black.opacity(peak), location: min(1, max(0, start)))]
        }
        return (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            return Gradient.Stop(
                color: .black.opacity(peak * eased(1 - t, bias: 1)),
                location: start + (end - start) * t
            )
        }
    }
}
#endif
