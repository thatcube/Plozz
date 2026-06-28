#if canImport(SwiftUI)
import SwiftUI

/// Centralised design tokens so spacing/sizing stay consistent and tweakable
/// in one place across all features. Think of this as the app's design-token
/// sheet (the SwiftUI equivalent of CSS custom properties): every gap, gutter
/// and inset should come from a token here rather than a hand-typed literal, so
/// the whole UI moves together and stays consistent.
public enum PlozzTheme {
    /// The compile-time density baseline. `scale` is fixed at `1.0` (standard):
    /// the tokens in `Spacing`/`Metrics` below are the **standard-density**
    /// constants and the tokens that never change with density (corner radii,
    /// focus scales, screen edge padding).
    ///
    /// The *live* per-profile UI-density preference is no longer driven from
    /// here — it is `CoreModels.UIDensity`, resolved into `PlozzMetrics` and
    /// injected via `@Environment(\.plozzMetrics)` at the app root. Media views
    /// (cards, grids, rails) read their scaled sizes/gaps from that environment
    /// value so a density change restyles them live; everything else keeps using
    /// these standard constants.
    public enum Density {
        /// The active multiplier applied to every step in `Spacing`. Fixed at
        /// standard density — see `CoreModels.UIDensity` / `PlozzMetrics` for the
        /// live, per-profile scaling.
        public static let scale: CGFloat = 1.0
    }

    /// The canonical spacing scale, in points at standard density. Semantic
    /// tokens in `Metrics` are expressed in terms of these steps so there is one
    /// ladder of spacing values and a density change moves all of them at once.
    public enum Spacing {
        private static func step(_ points: CGFloat) -> CGFloat {
            (points * Density.scale).rounded()
        }

        /// 4 pt — hairline gaps (e.g. a title and its subtitle).
        public static let xxSmall = step(4)
        /// 8 pt — tight inner padding.
        public static let xSmall = step(8)
        /// 12 pt — compact gaps.
        public static let small = step(12)
        /// 16 pt — a section's title-to-content gap, standard inner padding.
        public static let medium = step(16)
        /// 24 pt — the standard gap between media cards and grid gutters.
        public static let large = step(24)
        /// 32 pt — standard horizontal screen inset.
        public static let xLarge = step(32)
        /// 40 pt — vertical gap between stacked rows / sections.
        public static let xxLarge = step(40)
        /// 48 pt — generous headroom (e.g. focus-lift clearance under a rail).
        public static let xxxLarge = step(48)
    }

    public enum Metrics {
        // MARK: Card sizes (fixed artwork dimensions — not density-scaled)

        /// Standard poster card width (3:2-ish) tuned for tvOS 10-foot UI.
        public static let posterWidth: CGFloat = 280
        public static let posterHeight: CGFloat = 420
        public static let landscapeWidth: CGFloat = 480
        public static let landscapeHeight: CGFloat = 270

        // MARK: Spacing (derived from the `Spacing` scale)

        /// The single source of truth for the gap between adjacent media cards.
        /// Used by **every** poster/landscape rail *and* every poster grid, so the
        /// space between media reads identically across Home, Search, the library
        /// grid and detail rows — a tile in a Home rail sits the same distance
        /// from its neighbour as a tile in the library wall.
        public static let mediaSpacing = Spacing.large
        /// Inter-card gap in a horizontal rail. Same value as `gridSpacing` so a
        /// rail and a grid never disagree on how far apart cards sit.
        public static let cardSpacing = mediaSpacing
        /// Inter-card gap (both axes) in a poster grid.
        public static let gridSpacing = mediaSpacing
        /// Vertical gap between stacked rows / sections on a screen.
        public static let rowSpacing = Spacing.xxLarge
        /// Gap between a section's title and the row/grid beneath it.
        public static let sectionTitleSpacing = Spacing.medium
        /// Standard horizontal inset from the screen edge.
        public static let screenPadding = Spacing.xLarge
        /// Vertical inset at the very top/bottom of a screen's scroll content.
        public static let screenVerticalPadding = Spacing.xxLarge
        /// Headroom above a horizontal rail so a focused card's upward lift is
        /// never clipped by the scroll view's top edge.
        public static let railTopPadding = Spacing.medium
        /// Room below a rail for a focused card's lift + drop shadow so neither is
        /// clipped by the scroll view's bottom edge.
        public static let railVerticalPadding = Spacing.xxxLarge

        // MARK: Corner radii

        public static let cornerRadius: CGFloat = 12
        /// Poster (glass tile) surface + artwork corner radii. The shared
        /// browsing card used across Home rows, the library grid and Search,
        /// styled to match the Twozz "Browse" tile.
        public static let posterCardCornerRadius: CGFloat = 26
        public static let posterArtCornerRadius: CGFloat = 16
        /// Medium (landscape) card surface + media corner radii, matching the
        /// Twozz medium content card.
        public static let mediumCardCornerRadius: CGFloat = 22
        public static let mediumMediaCornerRadius: CGFloat = 18
        /// Content inset between a medium card's glass surface and its media.
        public static let mediumCardInset: CGFloat = 16

        // MARK: Focus

        /// Focus scale for a lifted medium card.
        public static let mediumFocusedCardScale: CGFloat = 1.07
        /// Scale applied to a focused browsing tile (matches Twozz Browse).
        public static let focusedCardScale: CGFloat = 1.08

        // MARK: Detail

        /// Leading inset for the detail hero's title/metadata block, shared by the
        /// rows beneath it (seasons, episodes, cast, chips) so the whole page lines
        /// up on one edge. Matches the standard `screenPadding` used by the Home
        /// rows so detail and Home content sit on the same left edge.
        public static let heroLeadingPadding: CGFloat = screenPadding
    }

    /// The shared dense poster grid — the "Browse" wall. A fixed number of
    /// flexible columns so each glass tile stretches to fill its column and the
    /// gutters stay small and consistent (no big adaptive gaps). Used by the
    /// library grid and Search so both have an identical column count and
    /// spacing; anything else that lays movie/show posters in a grid should use
    /// this too rather than rolling its own column maths.
    public enum Grid {
        /// Column count tuned for the tvOS 1920 pt-wide 10-foot UI.
        public static let columnCount = 7

        /// The grid's columns, carrying the shared gutter. Recomputed per access
        /// so a future density change to `gridSpacing` is reflected automatically.
        public static var posterColumns: [GridItem] {
            Array(
                repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing, alignment: .top),
                count: columnCount
            )
        }
    }
}

#endif
