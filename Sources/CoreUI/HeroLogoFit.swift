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

    // MARK: Ink

    /// Ink coverage taken as "normal" — the share of its own bounding box a
    /// typical wordmark actually paints. A logo at this value is left exactly as
    /// it was; everything else is measured against it.
    ///
    /// Around a third, which is what letter shapes leave once you account for
    /// counters, the gaps between words, and the transparent margin the trim
    /// stops at.
    static let referenceInk: Double = 0.32

    /// How hard to correct for ink. 0 disables the correction; 1 would equalise
    /// total ink exactly, which overshoots — a heavy slab face genuinely *is* a
    /// bolder logo and should still read as one. A third of the way there removes
    /// the glaring mismatches and leaves each logo recognisably itself.
    static let inkCorrectionStrength: Double = 0.35

    /// Bounds on the correction, as a linear scale. Deliberately asymmetric.
    ///
    /// Growing a thin logo is nearly free — a sparse wordmark has whitespace
    /// around it and the card has room. Shrinking a heavy one costs legibility on
    /// a card read from across a room, and a dense logo drawn small reads as
    /// cramped rather than as balanced. So the correction does most of its work by
    /// growing the light shapes rather than by shrinking the solid ones.
    static let minInkScale: CGFloat = 0.88
    static let maxInkScale: CGFloat = 1.22

    /// Where the correction starts fading out, and where it is gone entirely.
    ///
    /// Past a certain density an image stops being a wordmark: a logo whose solid
    /// plate survived stripping is a near-full rectangle, and shrinking it as if
    /// it were very heavy type would be wrong. But a hard cutoff there is worse —
    /// two logos a hair either side of it would be drawn at noticeably different
    /// sizes. So the correction eases back to neutral across this range instead of
    /// switching off at a line.
    static let inkFadeStart: Double = 0.62
    static let inkFadeEnd: Double = 0.9

    /// Linear scale correcting a logo's drawn size for how much **ink** it
    /// carries.
    ///
    /// Fitting by area gives every wordmark the same box to fill, which is the
    /// right first move — but it cannot see how much of that box is actually
    /// painted. A heavy slab face may cover half of it; a thin script an eighth.
    /// Identical area, and the slab reads as twice the logo. Ink coverage is the
    /// single variable that separates them, and correcting for it does more for
    /// consistency than width, height or colour individually.
    ///
    /// Damped rather than equalised: `pow` with a fractional exponent makes this a
    /// nudge. At strength 0.35 a logo carrying half the reference ink is drawn
    /// ~1.27× larger, not the 1.41× that equal total ink would demand.
    ///
    /// Continuous everywhere, including where it stops applying — a step in this
    /// curve would be visible as two similar logos drawn at different sizes.
    ///
    /// The measurement is free. ``PreparedLogo/coverage`` is already produced by
    /// the same pixel pass that trims and tones the logo, already cached per URL,
    /// and already runs off the main actor — so this adds arithmetic, not work.
    static func inkScale(coverage: Double) -> CGFloat {
        // Nothing measured at all — no ratio to form.
        guard coverage > 0 else { return 1 }
        let ratio = referenceInk / coverage
        let full = CGFloat(pow(ratio, inkCorrectionStrength))
        // The clamp is what makes a vanishingly small measurement safe, so there
        // is no need for a floor guard — and a guard there would itself be a cliff
        // (a logo at 0.019 coverage drawn a fifth smaller than one at 0.021).
        let clamped = min(maxInkScale, max(minInkScale, full))
        // Ease back to neutral as the image stops resembling a wordmark.
        guard coverage > inkFadeStart else { return clamped }
        guard coverage < inkFadeEnd else { return 1 }
        let t = (coverage - inkFadeStart) / (inkFadeEnd - inkFadeStart)
        let smooth = t * t * (3 - 2 * t)
        return clamped + (1 - clamped) * CGFloat(smooth)
    }

    /// The size to draw an image of `imageSize` at within a nominal
    /// `maxWidth` × `maxHeight` slot.
    ///
    /// May exceed either nominal bound (within ``widthFlex`` / ``heightFlex``) when
    /// the shape needs it. Deliberately upscales a small source: logo art arrives
    /// from several providers at different resolutions, and sizing by the source's
    /// own pixels made one show bold and another tiny for reasons having nothing to
    /// do with how either logo looks.
    ///
    /// - Parameter coverage: the logo's measured ink coverage
    ///   (``PreparedLogo/coverage``), which adjusts the area target so a thin
    ///   wordmark and a heavy one carry comparable weight. Omit it — or pass 1 —
    ///   to size on area alone.
    public static func fittedSize(
        for imageSize: CGSize,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        coverage: Double = 1
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, maxWidth > 0, maxHeight > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }
        // Height per unit of width: small for a wide wordmark, >= 1 for a tall logo.
        let aspect = imageSize.height / imageSize.width
        // Ink adjusts the AREA, which is what the fit solves for — so a thin logo
        // gets a bigger target in whichever direction its shape wants, exactly as
        // the area rule already does. Squared because `inkScale` is linear.
        let ink = inkScale(coverage: coverage)
        let target = maxWidth * maxHeight * targetAreaFraction * ink * ink
        // The ceilings deliberately do NOT take the ink scale. They are what keeps
        // a logo clear of the things around it — the card's edges, the chrome
        // below — and those distances are fixed by the layout, not by how much of
        // its own box a logo happens to paint. A thin wordmark may be given more
        // area; it may not be given permission to reach further.
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
