#if canImport(SwiftUI)
import SwiftUI

/// Centralised design tokens so spacing/sizing stay consistent and tweakable
/// in one place across all features.
public enum PlozzTheme {
    public enum Metrics {
        /// Standard poster card width (3:2-ish) tuned for tvOS 10-foot UI.
        public static let posterWidth: CGFloat = 280
        public static let posterHeight: CGFloat = 420
        public static let landscapeWidth: CGFloat = 480
        public static let landscapeHeight: CGFloat = 270
        public static let rowSpacing: CGFloat = 40
        public static let cardSpacing: CGFloat = 40
        /// Tighter spacing for dense multi-column library grids — small,
        /// consistent gutters so posters read as a dense wall, not islands.
        public static let gridSpacing: CGFloat = 24
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
        /// Focus scale for a lifted medium card.
        public static let mediumFocusedCardScale: CGFloat = 1.07
        /// Vertical padding around a horizontal rail so a focused card's lift and
        /// drop shadow are never clipped by the scroll view.
        public static let railVerticalPadding: CGFloat = 48
        /// Scale applied to a focused browsing tile (matches Twozz Browse).
        public static let focusedCardScale: CGFloat = 1.08
        public static let screenPadding: CGFloat = 32
        /// Leading inset for the detail hero's title/metadata block. Wider than
        /// `screenPadding` so the hero content sits in from the edge the way the
        /// Apple TV detail page does, rather than hugging the screen border.
        public static let heroLeadingPadding: CGFloat = 80
    }
}

#endif
