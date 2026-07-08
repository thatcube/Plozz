#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

/// The live, density-scaled spacing + sizing tokens, resolved from the active
/// profile's `UIDensity` and injected into the SwiftUI environment at the app
/// root (see `RootView`).
///
/// This is the runtime counterpart to `PlozzTheme.Metrics`: where `PlozzTheme`
/// holds the *standard-density* constants (and the tokens that never scale —
/// corner radii, focus scales, screen edge padding), `PlozzMetrics` holds the
/// subset that a density change must move: card artwork sizes, the poster wall's
/// column count, and the gaps between media. Media views read these via
/// `@Environment(\.plozzMetrics)` so changing the density setting (or switching
/// to a profile with a different density) restyles the whole media UI live, with
/// no view rebuild — exactly like the theme palette.
///
/// Anything that should *not* change with density (a card's corner radius, the
/// screen's edge inset) keeps reading the static `PlozzTheme.Metrics` constants.
public struct PlozzMetrics: Equatable, Sendable {
    /// The density this snapshot was resolved from.
    public let density: UIDensity
    /// The multiplier applied to every size/gap below (1.0 == standard).
    public let scale: CGFloat

    // MARK: Card artwork sizes (scaled)

    public let posterWidth: CGFloat
    public let posterHeight: CGFloat
    public let landscapeWidth: CGFloat
    public let landscapeHeight: CGFloat
    /// Inset between a media card's glass surface and its artwork — shared by
    /// poster *and* landscape cards so the glass border is a uniform thickness.
    public let cardInset: CGFloat

    // MARK: Circular tile sizes (scaled)

    /// Diameter of an artist's circular focus tile (density-scaled).
    public let artistTileDiameter: CGFloat
    /// Diameter of a cast member's circular focus tile (density-scaled).
    public let castTileDiameter: CGFloat
    /// Clearance between a circular avatar and its focus glass halo (scaled).
    public let circleFocusPadding: CGFloat

    // MARK: Focus caption movement (scaled)

    /// Distance a focused tile's caption drops on focus (scaled). Shared by the
    /// circular artist/cast tiles and the borderless cards.
    public let focusCaptionPush: CGFloat

    // MARK: Borderless ("Posters") card style (scaled)

    /// Horizontal breathing room reserved on each side of a borderless card inside
    /// its slot, so cards separate and the focus outline has room (scaled).
    public let borderlessCardSideMargin: CGFloat

    /// Height of a card's watched-progress bar, scaled with density and floored at
    /// `PlozzTheme.Metrics.progressBarMinHeight` so it tracks the display-size
    /// setting without ever shrinking to an illegible sliver.
    public let progressBarHeight: CGFloat

    /// Leg length of the "unwatched" corner flag, density-scaled and floored at
    /// `PlozzTheme.Metrics.unwatchedFlagMinSize` so it grows with the display-size
    /// setting yet never shrinks below a clearly-visible minimum on tiny cards.
    public let unwatchedFlagSize: CGFloat

    // MARK: Media spacing (scaled)

    /// Gap between adjacent media cards in a rail and gutter in a poster grid —
    /// one value so a rail and a grid never disagree.
    public let cardSpacing: CGFloat
    public let gridSpacing: CGFloat
    /// Vertical gap between stacked rows / sections on a screen.
    public let rowSpacing: CGFloat
    /// Gap between a section's title and the row/grid beneath it.
    public let sectionTitleSpacing: CGFloat
    /// Headroom above a rail so a focused card's upward lift isn't clipped.
    public let railTopPadding: CGFloat
    /// Room below a rail for a focused card's lift + drop shadow.
    public let railVerticalPadding: CGFloat
    /// Vertical room reserved *inside* a clipping rail for a focused card's lift +
    /// drop shadow (see `PlozzTheme.Metrics.railShadowClearance`). The rail pads
    /// its content by this on top and bottom, then negates it in layout via
    /// `railTopClearanceOffset` / `railBottomClearanceOffset` so the row keeps its
    /// real height and the clip simply grows to clear the shadow.
    public let railShadowClearance: CGFloat
    /// Negative top padding applied to a rail's scroll view to cancel the extra
    /// `railShadowClearance` headroom, restoring the intended `railTopPadding`.
    public var railTopClearanceOffset: CGFloat { railClearanceOffset(for: railTopPadding) }
    /// Negative bottom padding applied to a rail's scroll view to cancel the extra
    /// `railShadowClearance` room, restoring the intended `railVerticalPadding`.
    public var railBottomClearanceOffset: CGFloat { railClearanceOffset(for: railVerticalPadding) }
    /// Negative outer padding that cancels `railShadowClearance` down to an
    /// arbitrary `desired` rail inset, for rails whose top/bottom insets aren't the
    /// standard `railTopPadding`/`railVerticalPadding` (e.g. cast or music rails).
    /// Pairs with a `.padding(.vertical, railShadowClearance)` *inside* the clip:
    /// the net inset is exactly `desired`, so the row keeps its design height while
    /// the clip still grows enough to clear the focused card's shadow.
    public func railClearanceOffset(for desired: CGFloat) -> CGFloat { desired - railShadowClearance }

    // MARK: Poster grid

    /// Column count for the shared dense poster wall (library + search).
    public let posterGridColumns: Int

    // MARK: Caption fonts (scaled)

    /// Point size for a media card's title line, scaled with density so the text
    /// grows/shrinks with the card instead of staying fixed. At standard density
    /// this matches the platform `.subheadline` size, so standard looks unchanged.
    public let cardTitleFontSize: CGFloat
    /// Point size for a media card's subtitle/metadata line, scaled with density.
    public let cardSubtitleFontSize: CGFloat
    /// Point size for a section/row header, scaled with density but *dampened*
    /// (see `PlozzTheme.Metrics.headerScaleDamping`) so headers stay anchored.
    public let sectionHeaderFontSize: CGFloat

    /// The poster wall's columns, carrying the scaled gutter. Library and Search
    /// both use this so they share an identical column count and spacing.
    public var posterColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: gridSpacing, alignment: .top),
            count: posterGridColumns
        )
    }

    /// The layout width reserved for one landscape card in a rail — its full
    /// glass-surface width (artwork + both insets) so `cardSpacing` lands as a
    /// true visible gap between cards rather than overlapping the glass.
    public var landscapeCardSlotWidth: CGFloat {
        landscapeWidth + cardInset * 2
    }

    // MARK: Concentric card corner radii (derived)

    /// Outer (glass) corner radius for a poster ("Browse") card: its fixed inner
    /// artwork radius plus the shared `cardInset`. Deriving it this way keeps the
    /// glass border a true constant-width ring concentric with the artwork —
    /// `outer = inner + inset` — at every density.
    public var posterCardCornerRadius: CGFloat {
        PlozzTheme.Metrics.posterArtCornerRadius + cardInset
    }

    /// Outer (glass) corner radius for a landscape / music media card, derived
    /// from its inner media radius + `cardInset` for the same concentric border.
    public var landscapeCardCornerRadius: CGFloat {
        PlozzTheme.Metrics.mediumMediaCornerRadius + cardInset
    }

    // MARK: Caption corner-clearance (derived)

    /// Extra inset for a poster card's caption — *beyond* the shared `cardInset` —
    /// applied to its left, right *and* bottom so title/metadata text clears the
    /// rounded outer corners instead of crowding them, leaving the text in a
    /// balanced safe area. Sized so the text's total inset from the glass edge is
    /// `captionCornerClearanceFactor` × the outer radius, and scales with the
    /// radius (and thus density). The artwork is unaffected.
    public var posterCaptionInset: CGFloat {
        max(posterCardCornerRadius * PlozzTheme.Metrics.captionCornerClearanceFactor - cardInset, 0)
    }

    /// Landscape / music card counterpart of `posterCaptionInset`.
    public var landscapeCaptionInset: CGFloat {
        max(landscapeCardCornerRadius * PlozzTheme.Metrics.captionCornerClearanceFactor - cardInset, 0)
    }

    /// Gap between a poster card's artwork and its caption: the shared base
    /// (`cardCaptionSpacing`) plus a fraction (`captionTopClearanceFactor`) of the
    /// card's side/bottom `captionInset`, so the top breathing room scales up with
    /// the side clearance but only ~half as much (the top edge isn't a corner the
    /// text crowds).
    public var posterCaptionTopSpacing: CGFloat {
        PlozzTheme.Metrics.cardCaptionSpacing + posterCaptionInset * PlozzTheme.Metrics.captionTopClearanceFactor
    }

    /// Landscape / music card counterpart of `posterCaptionTopSpacing`.
    public var landscapeCaptionTopSpacing: CGFloat {
        PlozzTheme.Metrics.cardCaptionSpacing + landscapeCaptionInset * PlozzTheme.Metrics.captionTopClearanceFactor
    }

    public init(density: UIDensity) {
        let s = CGFloat(density.scale)
        self.density = density
        self.scale = s

        func step(_ base: CGFloat) -> CGFloat { (base * s).rounded() }
        /// Like `step`, but only applies `damping` of the density deviation from
        /// 1.0 — so `damping: 1` behaves exactly like `step`, `damping: 0` stays
        /// fixed at the base, and values between let an element nod to density
        /// without scaling 1:1 with the cards.
        func damped(_ base: CGFloat, _ damping: CGFloat) -> CGFloat {
            let effectiveScale = 1 + (s - 1) * damping
            return (base * effectiveScale).rounded()
        }

        // Card sizes derive from the standard-density constants in PlozzTheme.
        self.posterWidth = step(PlozzTheme.Metrics.posterWidth)
        self.posterHeight = step(PlozzTheme.Metrics.posterHeight)
        self.landscapeWidth = step(PlozzTheme.Metrics.landscapeWidth)
        self.landscapeHeight = step(PlozzTheme.Metrics.landscapeHeight)
        self.cardInset = step(PlozzTheme.Metrics.cardInset)

        self.artistTileDiameter = step(PlozzTheme.Metrics.artistTileDiameter)
        self.castTileDiameter = step(PlozzTheme.Metrics.castTileDiameter)
        self.circleFocusPadding = step(PlozzTheme.Metrics.circleFocusPadding)

        self.focusCaptionPush = step(PlozzTheme.Metrics.focusCaptionPush)
        self.borderlessCardSideMargin = step(PlozzTheme.Metrics.borderlessCardSideMargin)
        self.progressBarHeight = max(
            step(PlozzTheme.Metrics.progressBarHeight),
            PlozzTheme.Metrics.progressBarMinHeight
        )
        self.unwatchedFlagSize = max(
            step(PlozzTheme.Metrics.unwatchedFlagSize),
            PlozzTheme.Metrics.unwatchedFlagMinSize
        )

        self.cardSpacing = step(PlozzTheme.Metrics.cardSpacing)
        self.gridSpacing = step(PlozzTheme.Metrics.gridSpacing)
        // Inter-row dead space is dampened so it doesn't grow 1:1 with the cards
        // — that's what keeps the next row peeking into view at high densities.
        self.rowSpacing = damped(PlozzTheme.Metrics.rowSpacing, PlozzTheme.Metrics.rowSpacingDamping)
        // The header-to-row gap follows the (dampened) header type so each header
        // keeps hugging its own row at every density.
        self.sectionTitleSpacing = damped(PlozzTheme.Metrics.sectionTitleSpacing, PlozzTheme.Metrics.headerScaleDamping)
        self.railTopPadding = step(PlozzTheme.Metrics.railTopPadding)
        self.railVerticalPadding = step(PlozzTheme.Metrics.railVerticalPadding)
        // The lift portion scales with the card; the shadow's own reach is a fixed
        // pixel size (radius 20 + y 10) that must NOT shrink at low density or it
        // would clip, so it's added unscaled.
        self.railShadowClearance = step(PlozzTheme.Metrics.railShadowLiftAllowance)
            + PlozzTheme.Metrics.railShadowFixedExtent

        self.posterGridColumns = density.posterGridColumns

        // Caption fonts scale with density too. The title's base is the live
        // platform `.subheadline` size so standard density is unchanged; the
        // subtitle's base is the shared `cardSubtitleFontSize` constant.
        #if canImport(UIKit)
        let baseTitleFontSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        #else
        let baseTitleFontSize = PlozzTheme.Metrics.cardTitleFontSizeFallback
        #endif
        self.cardTitleFontSize = (baseTitleFontSize * s).rounded()
        self.cardSubtitleFontSize = step(PlozzTheme.Metrics.cardSubtitleFontSize)
        // Section headers scale with density but dampened, so they anchor the page
        // hierarchy instead of ballooning/shrinking 1:1 with the cards.
        self.sectionHeaderFontSize = damped(PlozzTheme.Metrics.sectionHeaderFontSize, PlozzTheme.Metrics.headerScaleDamping)
    }

    /// The standard-density snapshot, used as the environment default so any view
    /// that hasn't yet been wired to a profile still renders at standard density.
    public static let standard = PlozzMetrics(density: .standard)
}

// MARK: - Environment plumbing

private struct PlozzMetricsKey: EnvironmentKey {
    static let defaultValue = PlozzMetrics.standard
}

public extension EnvironmentValues {
    /// The live, density-scaled media metrics for the active profile, injected at
    /// the app root. Media views read this so a density change restyles them live.
    var plozzMetrics: PlozzMetrics {
        get { self[PlozzMetricsKey.self] }
        set { self[PlozzMetricsKey.self] = newValue }
    }
}

#endif
