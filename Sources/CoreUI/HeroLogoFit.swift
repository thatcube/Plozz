import CoreGraphics
import Foundation

/// How a hero wordmark is sized inside its slot, so every logo carries the same
/// visual weight regardless of its shape.
///
/// Fitting to a width cap and a height cap sounds neutral but isn't. A wide
/// wordmark fills the width and never approaches the height limit; a tall,
/// poster-shaped logo hits the height limit at once and its width collapses; a
/// very wide, short wordmark fills the width but stays a thin strip. Measured
/// across five real logos the same rule produced a **3.4× spread** in area —
/// "Sleepy Princess" at 18k against "Avatar" at 62k — so a show's presence on
/// screen came down to the shape of its logo rather than anything about the show.
///
/// The fix is to solve for **area** instead. Every logo aims to cover the same
/// number of points, and the slot flexes in whichever direction that shape needs:
/// extra width for a thin wordmark, extra height for a tall one. Neither costs
/// anything — a thin logo has height to spare, a tall one has width to spare.
public enum HeroLogoFit {

    /// The share of the nominal slot every logo aims to cover.
    ///
    /// Set to what a typical wide wordmark already occupies, so the shape that
    /// looks right today is unchanged and only the penalised shapes move.
    static let targetAreaFraction: CGFloat = 0.775

    /// How far past the nominal width a *thin* logo may stretch. Bounded so a
    /// wordmark still aligns roughly with the text and buttons beneath it.
    static let widthFlex: CGFloat = 1.25

    /// How far past the nominal height a *tall* logo may grow. Larger than the
    /// width flex because vertical room is cheaper here: a tall logo is narrow, so
    /// it crowds nothing beside it.
    static let heightFlex: CGFloat = 1.5

    /// The size to draw an image of `imageSize` at within a nominal
    /// `maxWidth` × `maxHeight` slot.
    ///
    /// May exceed either nominal bound (within ``widthFlex`` / ``heightFlex``) when
    /// the shape needs it. Deliberately upscales a small source: logo art arrives
    /// from several providers at different resolutions, and sizing by the source's
    /// own pixels made one show bold and another tiny for reasons having nothing to
    /// do with how either logo looks.
    public static func fittedSize(
        for imageSize: CGSize,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, maxWidth > 0, maxHeight > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }
        // Height per unit of width: small for a wide wordmark, >= 1 for a tall logo.
        let aspect = imageSize.height / imageSize.width
        let target = maxWidth * maxHeight * targetAreaFraction
        let widthCeiling = maxWidth * widthFlex
        let heightCeiling = maxHeight * heightFlex

        // The size covering `target` at this aspect: area = w * (w * aspect).
        var width = (target / aspect).squareRoot()
        var height = width * aspect

        // Clamp width first, then height. Narrowing also shortens (height follows
        // width at a fixed aspect), so the second clamp can't re-break the first.
        if width > widthCeiling {
            width = widthCeiling
            height = width * aspect
        }
        if height > heightCeiling {
            height = heightCeiling
            width = height / aspect
        }
        return CGSize(width: width, height: height)
    }
}
