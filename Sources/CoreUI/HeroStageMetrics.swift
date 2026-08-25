#if canImport(SwiftUI)
import CoreGraphics
import Foundation

/// How tall a portrait Home hero stands on a phone, and how that height splits
/// between the picture and the mirrored continuation beneath it.
///
/// Both halves answer the same question from opposite ends. The hero has to be
/// tall enough that its metadata — wordmark, genres, ratings, actions — sits in
/// the lower part of the screen where a thumb is, rather than floating in the
/// middle of the artwork; and short enough that the row underneath still peeks
/// above the fold, which is the only thing that tells someone opening Home for
/// the first time that it scrolls. A fixed point height cannot satisfy both a
/// 4.7" phone and a 6.9" one, so the height is a **fraction of the window**.
///
/// Growing a hero would ordinarily mean cropping its artwork harder, because a
/// hero fills its slot: 16:9 backdrop art already runs near 3x zoom on a
/// portrait phone, and the taller the slot the worse that gets. So the picture
/// keeps the crop it had and the shortfall is filled with a mirrored
/// continuation of its own bottom edge — the Continue Watching card trick. That
/// is why the split is computed by the very same ``ExtendedArtworkGeometry``
/// those cards use rather than by a second implementation of it: one mirror,
/// one set of rules.
public enum HeroStageMetrics {
    /// Fraction of the window height a portrait Home hero occupies.
    ///
    /// The remainder is the peek: at this share a 6.9" phone leaves roughly
    /// 230pt below the hero, which is the row heading plus about half a
    /// Continue Watching card — enough to read as "there is more down here"
    /// without giving up the immersive full-bleed top.
    public static let portraitHomeHeightShare: CGFloat = 0.76

    /// Floor for the hero on the smallest phones, where 76% of a short window
    /// would leave too little room for the metadata column to sit in.
    public static let portraitHomeMinimumHeight: CGFloat = 520

    /// Ceiling, so an iPad in a portrait-width window (or any unexpectedly tall
    /// container) doesn't produce a hero the length of a page.
    public static let portraitHomeMaximumHeight: CGFloat = 900

    /// Width ÷ height of the hero's picture band — the shape the artwork is
    /// cropped into before the mirror takes over.
    ///
    /// 5:7 keeps the picture at the crop the hero had when its height was a flat
    /// 610pt on a 440pt-wide phone, so this change buys height without taking
    /// any more of the image away. Expressed as a ratio rather than a constant
    /// because a narrower phone was previously cropped *harder* for the same
    /// 610pt — the one thing a fixed height guarantees is an inconsistent crop.
    public static let portraitPictureAspectRatio: CGFloat = 5.0 / 7.0

    /// The most of the hero the mirror is allowed to be.
    ///
    /// Only bites when the hero is stretched well past its natural proportion —
    /// an accessibility Dynamic Type size, which adds height for text the
    /// picture didn't ask for. Past this point the picture is zoomed (via a side
    /// trim, exactly as a Continue Watching card is) rather than letting the
    /// reflection grow to a third of the screen, which stops reading as a
    /// reflection and starts reading as a second, upside-down picture.
    public static let maximumReflectionShare: CGFloat = 0.24

    /// Hero height for a given window.
    ///
    /// - Parameters:
    ///   - windowHeight: the whole window, not the safe area — the hero runs
    ///     full-bleed under the status bar, and the peek is measured against the
    ///     bottom of the screen. `nil` before the window has been measured.
    ///   - fallback: height to use until then.
    ///   - accessibilityExtra: height added for an accessibility Dynamic Type
    ///     size. Added *after* the clamp: the ceiling exists to stop the hero
    ///     dominating a large screen, not to withhold room that text needs.
    public static func portraitHomeHeight(
        windowHeight: CGFloat?,
        fallback: CGFloat,
        accessibilityExtra: CGFloat = 0
    ) -> CGFloat {
        guard let windowHeight, windowHeight > 0 else {
            return fallback + accessibilityExtra
        }
        let share = windowHeight * portraitHomeHeightShare
        let clamped = min(
            max(share, portraitHomeMinimumHeight),
            portraitHomeMaximumHeight
        )
        return clamped + accessibilityExtra
    }

    /// The picture / mirror split for a hero stage of this size.
    public static func geometry(
        width: CGFloat,
        height: CGFloat
    ) -> ExtendedArtworkGeometry {
        ExtendedArtworkGeometry(
            slot: CGSize(width: width, height: height),
            artworkAspectRatio: portraitPictureAspectRatio,
            sideCrop: sideCrop(width: width, height: height)
        )
    }

    /// The side trim needed to keep the mirror within
    /// ``maximumReflectionShare``. Zero whenever the picture already stands tall
    /// enough, which is the ordinary case.
    static func sideCrop(width: CGFloat, height: CGFloat) -> CGFloat {
        guard width > 0, height > 0, portraitPictureAspectRatio > 0 else {
            return 0
        }
        let natural = width / portraitPictureAspectRatio
        let floor = height * (1 - maximumReflectionShare)
        guard natural < floor else { return 0 }
        // The picture stands `renderedWidth / aspect` tall, and `renderedWidth`
        // is `width / visible` — so the visible fraction that lands the picture
        // exactly on the floor is the ratio of the two heights.
        let visible = natural / floor
        return max(0, (1 - visible) / 2)
    }

    /// The shortest distance the hero's bottom dissolve is ever given to happen
    /// in, in points.
    ///
    /// A floor, and the reason one is needed: the mirror line is not always a
    /// safe place to start melting from. On a narrow phone the picture is
    /// naturally about as tall as the whole hero — 375pt of width at the 5:7
    /// picture shape is 525pt, against a 520pt stage — so there is no mirror band
    /// at all and the mirror line sits at 1.0. Melting from there gives the
    /// dissolve the last few points of the hero, which is a hard cut from
    /// full-brightness artwork straight to page background rather than a melt.
    /// Measured on an iPhone SE (3rd generation).
    ///
    /// Points rather than a fraction because this is a perceptual distance — how
    /// far the eye travels before it stops registering an edge — and a fraction
    /// would quietly mean a different distance on every screen, which is the bug
    /// class this type exists to end.
    public static let minimumMeltSpan: CGFloat = 130

    /// Where the hero's bottom dissolve begins, as a fraction of its height.
    ///
    /// Holds the picture whole down to its mirror line (scaled by `mirrorScale`,
    /// which lets a light page start the melt earlier than a dark one), never
    /// starts earlier than `floor`, and never starts so late that the dissolve
    /// has less than ``minimumMeltSpan`` to happen in.
    public static func meltStart(
        width: CGFloat,
        height: CGFloat,
        mirrorScale: CGFloat,
        floor: CGFloat
    ) -> CGFloat {
        guard width > 0, height > 0 else { return floor }
        let mirrorLine = geometry(width: width, height: height).reflectionStart
        // Never leave the dissolve less room than it needs, and never let the
        // guarantee itself eat more than half the hero.
        let latest = 1 - min(minimumMeltSpan / height, 0.5)
        return min(max(mirrorLine * mirrorScale, floor), latest)
    }
}
#endif
