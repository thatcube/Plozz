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

    /// Opacity at the mirror line and at the bottom of the card, applied as a
    /// wash of the black the band sits on rather than as a mask — same result,
    /// one less offscreen pass per card in a rail that scrolls.
    ///
    /// It starts below full strength on purpose. A reflection that begins at the
    /// picture's own brightness reads as more photograph — the viewer looks for
    /// meaning in it — where a clean step at the seam says "surface" immediately,
    /// which is the whole point: the eye should stop at the mirror line and treat
    /// everything under it as the card, not the picture.
    private static var seamWash: CGFloat { 0.15 }
    private static var footWash: CGFloat { 0.90 }

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
            VStack(spacing: 0) {
                sizedPicture(geometry)
                    .frame(width: geo.size.width, height: geometry.pictureHeight)
                    .clipped()
                if geometry.reflectionHeight > 0 {
                    reflection(geometry, width: geo.size.width)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    /// The artwork at its own shape, rendered wide enough that the slot trims a
    /// sliver from each side.
    private func sizedPicture(_ geometry: ExtendedArtworkGeometry) -> some View {
        picture
            .frame(width: geometry.renderedWidth, height: geometry.pictureHeight)
    }

    /// The band under the picture: the same image flipped vertically, so its top
    /// row is the picture's last row and the two meet with no seam of their own,
    /// then washed out downward into the black it stands on.
    ///
    /// Left deliberately **unblurred**. A blur would be a full-band GPU filter on
    /// every card of a rail that scrolls, and it would also have to sample the
    /// transparency just past the mirror line, which puts a bright hairline along
    /// the exact edge the effect depends on being invisible. The wash does the
    /// same job for free: it drops away fast enough that there is no detail left
    /// to mistake for picture within the first third of the band.
    private func reflection(_ geometry: ExtendedArtworkGeometry, width: CGFloat) -> some View {
        // Opaque, so a borderless card can't go see-through at its foot where the
        // wash is almost complete.
        Color.black
            .frame(width: width, height: geometry.reflectionHeight)
            .overlay(alignment: .top) {
                sizedPicture(geometry)
                    .scaleEffect(x: 1, y: -1)
            }
            .clipped()
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(Self.seamWash), location: 0),
                        // Front-loaded: most of the fall happens in the top third,
                        // which is where a mirrored face or caption would still be
                        // legible enough to distract.
                        .init(color: .black.opacity(Self.footWash * 0.72), location: 0.34),
                        .init(color: .black.opacity(Self.footWash), location: 1)
                    ],
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
    /// Width ÷ height of the whole card.
    public static var aspectRatio: CGFloat {
        PlozzTheme.Metrics.continueWatchingCardAspectRatio
    }

    /// Bands of a card of this shape carrying 16:9 art.
    public static var geometry: ExtendedArtworkGeometry {
        // Pure ratios: a slot one unit tall describes the shape completely.
        ExtendedArtworkGeometry(
            slot: CGSize(width: aspectRatio, height: 1),
            artworkAspectRatio: 16.0 / 9.0,
            sideCrop: PlozzTheme.Metrics.continueWatchingArtworkSideCrop
        )
    }

    /// Where the picture ends and its reflection begins, as a fraction of the
    /// card's height. Also the share of the card the logo has to itself.
    public static var mirrorLine: CGFloat { geometry.reflectionStart }

    /// Where the chrome's legibility scrim starts darkening.
    ///
    /// A little **above** the mirror line rather than exactly on it. The chip's
    /// text is taller than the reflection band is deep, so a ramp starting at the
    /// seam leaves the tops of the glyphs on bare picture; this gives them a bed
    /// while costing the picture only its last few percent — which the chip is
    /// standing in front of anyway.
    public static var scrimStart: CGFloat { max(0.34, mirrorLine - 0.06) }

    /// Fraction of the card's width the logo may occupy.
    ///
    /// A logo is nearly always wider than it is tall, so this — not the height —
    /// is what actually decides how big it looks.
    public static let logoWidthFraction: CGFloat = 0.74

    /// Fraction of the *picture band* the logo may occupy vertically. Measured
    /// against the picture rather than the card so the logo is centred in the
    /// image and the chrome band underneath stays its own space.
    public static let logoHeightFraction: CGFloat = 0.42
}
#endif
