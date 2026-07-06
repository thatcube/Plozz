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

        // MARK: Circular tile sizes (round avatars: artists, cast)

        /// Diameter of an artist's circular tile — kept close to a music card's
        /// artwork so an Artists rail reads at the same scale as Albums/Playlists.
        /// Density-scaled in `PlozzMetrics`.
        public static let artistTileDiameter: CGFloat = 230
        /// Diameter of a cast member's circular tile — a deliberately smaller
        /// variant of the same style. Density-scaled in `PlozzMetrics`.
        public static let castTileDiameter: CGFloat = 150
        /// Thickness of the shared focus **halo** — the translucent liquid-glass
        /// ring that blooms around a focused tile. Used identically by the circular
        /// artist/cast tiles and the borderless ("Posters") card style, so all three
        /// share one focus-frame thickness. It is the width of the visible ring on
        /// focus (the halo scales with its content, so the band stays this wide at
        /// any tile size). Density-scaled in `PlozzMetrics`.
        public static let circleFocusPadding: CGFloat = 8

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
        /// Vertical gap between stacked rows / sections on a screen. Kept a little
        /// tighter than a full `Spacing` step (28 vs 40) so the wall of rows reads
        /// densely rather than airy — the dominant "dead space" lever on the page.
        public static let rowSpacing: CGFloat = 28
        /// Gap between a section's title and the row/grid beneath it.
        public static let sectionTitleSpacing = Spacing.medium
        /// Standard horizontal inset from the screen edge.
        public static let screenPadding = Spacing.xLarge
        /// Max content width for the Settings screens so cards/lists don't
        /// stretch edge-to-edge on a wide TV. Shared by the root Settings page
        /// and the drill-in detail pages (Servers, Profiles) so they all read
        /// at the same width.
        public static let settingsContentMaxWidth: CGFloat = 1200
        /// Vertical inset at the very top/bottom of a screen's scroll content.
        public static let screenVerticalPadding = Spacing.xLarge
        /// Headroom above a horizontal rail so a focused card's upward lift is
        /// never clipped by the scroll view's top edge.
        public static let railTopPadding = Spacing.medium
        /// Room below a rail for a focused card's lift + drop shadow so neither is
        /// clipped by the scroll view's bottom edge. Sized to just clear the focus
        /// shadow (radius 20 + y 10) plus the card's lift, so it can't be trimmed
        /// much further without the shadow visibly crowding the next row.
        public static let railVerticalPadding = Spacing.xxLarge
        /// Vertical room reserved *inside* a horizontal rail's scroll clip for a
        /// focused card's lift + drop shadow. A rail must **clip** its bounds —
        /// disabling the clip makes the tvOS focus engine miscompute the edge and
        /// yank the first/last card flush to the screen, eating its inset. So the
        /// rail keeps clipping and instead pads its content by this much on the top
        /// and bottom *inside* the clip, then cancels the same amount in layout
        /// (see `PlozzMetrics.railTopClearanceOffset`) so the row's height — and the
        /// gap to its neighbours — is byte-for-byte unchanged. Built from two parts
        /// in `PlozzMetrics`:
        ///   • `railShadowLiftAllowance` — the focused card's *lift*, which grows
        ///     with the card, so it is density-scaled.
        ///   • `railShadowFixedExtent` — the drop shadow's own reach (radius 20 +
        ///     y 10). The shadow radius is a fixed pixel value that does **not**
        ///     shrink at low densities, so this part stays fixed; scaling it would
        ///     let the shadow clip at micro density.
        public static let railShadowLiftAllowance: CGFloat = 28
        public static let railShadowFixedExtent: CGFloat = 32

        // MARK: Corner radii

        public static let cornerRadius: CGFloat = 12

        // A media card (poster or landscape) nests clipped artwork inside a glass
        // surface, separated by `cardInset` on every side. For the rounded border
        // to read as a *constant-width* ring, the two rounded rects must be
        // concentric:
        //     outer (glass) radius = inner (media) radius + cardInset
        // The inner (media) radii below are the fixed, design-tuned values; the
        // outer (glass) radii are *derived* from them in `PlozzMetrics`
        // (`posterCardCornerRadius` / `landscapeCardCornerRadius`), so the glass
        // corner always stays concentric with the artwork at every density.

        /// Inner artwork corner radius for a poster ("Browse") card. Matches Twozz.
        public static let posterArtCornerRadius: CGFloat = 16
        /// Inner media corner radius for a landscape (medium) card. Matches Twozz.
        public static let mediumMediaCornerRadius: CGFloat = 18
        /// Uniform inset between a media card's glass surface and its artwork —
        /// shared by **every** poster *and* landscape card so the glass border
        /// reads the same thickness across the whole UI. Density-scaled in
        /// `PlozzMetrics`; the outer glass radii are derived from it.
        public static let cardInset: CGFloat = 12
        /// Corner radius for standalone glass *panels* (settings cards, the mini
        /// player) — surfaces that don't nest inset artwork, so they aren't bound
        /// by the concentric rule above and keep a fixed radius. Tuned to match
        /// the aggressive rounding of Home's poster glass (`posterArtCornerRadius`
        /// + `cardInset` = 28) so panels read as part of the same card family.
        public static let mediumCardCornerRadius: CGFloat = 28

        /// **Global corner-radius scale** — one shared vocabulary of radii so every
        /// card, panel and nested surface reads with the same roundness, *regardless
        /// of the Display Size setting* (radii never density-scale). Values are
        /// aligned with the media-card family above so standalone panels and poster
        /// cards look like one family.
        ///
        /// Concentric rule (same as the media cards): content nested inside a
        /// `panel` with `inset` padding uses `content` (= `panel − inset`), so their
        /// rounded corners stay concentric — a constant-width ring.
        public enum Radius {
            /// Outer radius for standalone cards & panels — settings/preview cards,
            /// glass panels, the mini player. Matches Home's poster-glass family
            /// (== `mediumCardCornerRadius`).
            public static let panel: CGFloat = 28
            /// Medium container radius — grouped list boxes, cards, overlays.
            public static let card: CGFloat = 22
            /// Content nested inside a `panel` with `inset` padding; stays
            /// concentric with the panel (`panel − inset`). Matches poster artwork
            /// (== `posterArtCornerRadius`).
            public static let content: CGFloat = 16
            /// Small controls / compact chips, buttons, rows, PIN & QR frames.
            public static let control: CGFloat = 16
            /// The concentric gap between a `panel` and its nested `content`
            /// (`panel − content`; == `cardInset` base).
            public static let inset: CGFloat = 12
        }
        /// Optical clearance factor for a media card's caption: the title/metadata
        /// text is inset horizontally from the glass edge by this fraction of the
        /// card's *outer* corner radius, so left-aligned text clears the rounded
        /// corner instead of crowding it. ~0.8 keeps text off the curve while
        /// staying visually tied to the artwork's edge. Applied per-card in
        /// `PlozzMetrics` (artwork itself is unaffected).
        public static let captionCornerClearanceFactor: CGFloat = 0.8
        /// Vertical gap between a media card's artwork and its caption block —
        /// the *base* shared by every poster and landscape card. The artwork sits
        /// flush against the top corner curve (unlike the side/bottom text, which
        /// is held off it by `captionInset`), so the gap above the title only needs
        /// to grow by a *fraction* of that side inset — see
        /// `captionTopClearanceFactor` and the derived `…CaptionTopSpacing`.
        public static let cardCaptionSpacing: CGFloat = 8
        /// How much of a caption's side/bottom `captionInset` is added to the gap
        /// above the title. The top edge isn't a rounded corner the text crowds
        /// (the artwork is), so the title needs less added space there than the
        /// sides — ~half reads balanced. Applied in `PlozzMetrics`.
        public static let captionTopClearanceFactor: CGFloat = 0.5
        /// Base (standard-density) point size for a card's subtitle/metadata line.
        /// Density-scaled in `PlozzMetrics` so caption text grows with the card.
        public static let cardSubtitleFontSize: CGFloat = 20
        /// Fallback base point size for a card's title when the platform's live
        /// `.subheadline` metric is unavailable (non-UIKit builds). On tvOS the
        /// real `.subheadline` size is used so standard density is unchanged.
        public static let cardTitleFontSizeFallback: CGFloat = 29
        /// Base (standard-density) point size for a section/row header ("Continue
        /// Watching", "Libraries", a search group title…). Density-scaled in
        /// `PlozzMetrics`, but *dampened* (see `headerScaleDamping`) so headers
        /// anchor the page hierarchy instead of ballooning with the cards.
        public static let sectionHeaderFontSize: CGFloat = 32
        /// How strongly structural type — the section headers and the gap that
        /// ties each header to its row — follows the density scale. `1` = full
        /// 1:1 response (grows/shrinks exactly with the cards), `0` = fixed. A
        /// value near `0.5` lets headers nod to density while keeping the app's
        /// hierarchy stable across every size. Applied in `PlozzMetrics`.
        public static let headerScaleDamping: CGFloat = 0.5
        /// How strongly the *vertical gap between stacked rows* follows the density
        /// scale. Lower than `headerScaleDamping` on purpose: the cards already
        /// grow with density, so letting this dead space grow linearly too would
        /// push the next row off-screen. Damping it keeps rows close enough that
        /// the following row still peeks at high densities. Applied in `PlozzMetrics`.
        public static let rowSpacingDamping: CGFloat = 0.35

        // MARK: Focus

        /// Focus scale for a lifted medium card.
        public static let mediumFocusedCardScale: CGFloat = 1.07
        /// Scale applied to a focused browsing tile (matches Twozz Browse).
        public static let focusedCardScale: CGFloat = 1.08

        // MARK: Focus caption movement

        /// Vertical distance a focused tile's caption drops on focus, shared by the
        /// circular artist/cast tiles and the borderless ("Posters") cards so labels
        /// move identically everywhere. The gap slot is always reserved at this
        /// larger size and the caption rides *up* when unfocused via a transform, so
        /// the drop never changes the tile's footprint. Base value; density-scaled
        /// in `PlozzMetrics` so it tracks the display-size preference.
        public static let focusCaptionPush: CGFloat = 16

        // MARK: Borderless ("Posters") card style

        /// Horizontal breathing room reserved on each side of a borderless card
        /// *inside* its layout slot. It restores the separation the glass frame's
        /// `cardInset` used to provide (borderless artwork would otherwise butt
        /// right up to the inter-card gap) and gives the focus outline + lift room
        /// to bloom without touching the neighbouring card. Kept smaller than
        /// `cardInset` so a borderless poster still reads larger than the framed
        /// card's inset artwork. Base value; density-scaled in `PlozzMetrics`.
        public static let borderlessCardSideMargin: CGFloat = 10

        /// Base height of a card's watched-progress bar. Density-scaled (with a
        /// floor at `progressBarMinHeight`) in `PlozzMetrics`, so the scrubber
        /// grows/shrinks with the display-size setting like the rest of the card
        /// instead of staying a fixed pixel height.
        public static let progressBarHeight: CGFloat = 12
        /// Smallest the density-scaled progress bar is allowed to get, so it stays
        /// legible at the smallest display-size settings.
        public static let progressBarMinHeight: CGFloat = 9

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
