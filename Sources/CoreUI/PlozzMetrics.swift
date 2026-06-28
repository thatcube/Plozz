#if canImport(SwiftUI)
import SwiftUI
import CoreModels

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

    // MARK: Poster grid

    /// Column count for the shared dense poster wall (library + search).
    public let posterGridColumns: Int

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

    public init(density: UIDensity) {
        let s = CGFloat(density.scale)
        self.density = density
        self.scale = s

        func step(_ base: CGFloat) -> CGFloat { (base * s).rounded() }

        // Card sizes derive from the standard-density constants in PlozzTheme.
        self.posterWidth = step(PlozzTheme.Metrics.posterWidth)
        self.posterHeight = step(PlozzTheme.Metrics.posterHeight)
        self.landscapeWidth = step(PlozzTheme.Metrics.landscapeWidth)
        self.landscapeHeight = step(PlozzTheme.Metrics.landscapeHeight)
        self.cardInset = step(PlozzTheme.Metrics.cardInset)

        self.cardSpacing = step(PlozzTheme.Metrics.cardSpacing)
        self.gridSpacing = step(PlozzTheme.Metrics.gridSpacing)
        self.rowSpacing = step(PlozzTheme.Metrics.rowSpacing)
        self.sectionTitleSpacing = step(PlozzTheme.Metrics.sectionTitleSpacing)
        self.railTopPadding = step(PlozzTheme.Metrics.railTopPadding)
        self.railVerticalPadding = step(PlozzTheme.Metrics.railVerticalPadding)

        self.posterGridColumns = density.posterGridColumns
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
