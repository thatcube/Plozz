#if canImport(SwiftUI)
import SwiftUI
import CoreModels

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

        // MARK: Continue Watching (logo & artwork) card shape

        /// How much reflection a Continue Watching card shows, as a fraction of
        /// the picture's own height.
        ///
        /// This — not an aspect ratio — is the number worth choosing, because it
        /// is the thing you actually see: the card's shape falls out of it (see
        /// ``ContinueWatchingCardShape/aspectRatio``). The card is taller than its
        /// 16:9 art so the chrome along the bottom — play glyph, progress bar,
        /// "S1, E12 · 17m" — sits in a band of its own rather than on top of the
        /// subject, and this says how deep that band is.
        ///
        /// Kept modest. Height is what a rail spends, and past a point the
        /// reflection stops reading as the picture having a soft bottom and
        /// starts being a feature of its own that the chip then sits on top of.
        public static let continueWatchingReflectionShare: CGFloat = 0.135
        /// Fraction of the artwork's width trimmed from **each** side of a
        /// Continue Watching card.
        ///
        /// The picture keeps its own 16:9 shape and is never squashed. Trimming a
        /// sliver off each side scales it up, so it stands taller in the card and
        /// less of the card is left to fill underneath it — 3% a side costs
        /// nothing anyone can see on a backdrop (whose subject is centred) and
        /// buys back roughly a fifth of the fill band.
        public static let continueWatchingArtworkSideCrop: CGFloat = 0.03
    
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
        /// Horizontal inset of top-level content from the screen edge, applied *on
        /// top of* the tvOS title-safe **safe area** the system already hands us.
        /// `0` means "sit flush against the system safe area" — the same thing
        /// Apple's own TV apps do, so our rails/hero/text sit as close to the edge
        /// as the platform allows without adding a second, redundant margin. This
        /// is the single shared value for the screen-edge inset; don't hard-code a
        /// number at call sites. (Use `screenVerticalPadding` for top/bottom and
        /// inner block spacing — that is a *different* concern and stays non-zero.)
        public static let screenPadding: CGFloat = 0
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
        /// Shared outer radius for the video player's info and diagnostics panels.
        public static let playerPanelCornerRadius: CGFloat = mediumMediaCornerRadius + 24

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
        /// Search-only status cue painted on media artwork. It scales with the card
        /// but is floored in `PlozzMetrics` so micro density remains TV-readable.
        public static let cardStatusCueFontSize: CGFloat = 18
        public static let cardStatusCueMinFontSize: CGFloat = 16
        public static let cardStatusCueHorizontalPadding: CGFloat = 10
        public static let cardStatusCueMinHorizontalPadding: CGFloat = 8
        public static let cardStatusCueVerticalPadding: CGFloat = 6
        public static let cardStatusCueMinVerticalPadding: CGFloat = 5
        /// Resume-chip (play glyph + progress bar + "… left") drawn on landscape
        /// artwork. tvOS's tuned constants: read from ~10ft, so the glyph is large
        /// and the bar is comfortably readable without dominating the chip. iOS derives its own from real text styles in
        /// `PlozzMetrics` — applying these there would reproduce the caption bug
        /// (a tvOS constant that reads as secondary on a 29pt title but is larger
        /// than iOS's 15pt title).
        public static let resumeChipFontSize: CGFloat = 24
        public static let resumeChipInset: CGFloat = 18
        public static let resumeChipBarWidth: CGFloat = 56
        public static let resumeChipBarHeight: CGFloat = 8
        public static let resumeChipAccessorySize: CGFloat = 30
        /// Glyph size for the artwork "…" menu. Distinct from the download badge:
        /// the badge is a status readout, this is a HIT TARGET, so it's sized for
        /// the finger (and the tvOS remote) rather than to match adjacent text.
        public static let artworkMenuGlyphSize: CGFloat = 26
        /// Tap target. 44pt is Apple's minimum comfortable touch size (HIG); tvOS
        /// scales up with the rest of its chrome.
        public static let artworkMenuTargetSize: CGFloat = 52
        /// Inset from the artwork's edge. Must clear the rounded corner so the
        /// glyph doesn't collide with the curve.
        public static let artworkMenuInset: CGFloat = 10
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
        /// Focus lift for large read-only information cards (About, Details,
        /// Playback). Gentler than a media card's: these are wide, text-heavy
        /// panels, and a browse-card scale on one reads as the whole column
        /// jumping.
        public static let readOnlyFocusedCardScale: CGFloat = 1.02
        /// Scale applied to a focused browsing tile (matches Twozz Browse).
        public static let focusedCardScale: CGFloat = 1.08

        // MARK: Focus — "Highlight" style (outline off)

        /// The scale a focused card grows to when the focus outline is switched
        /// off (`CardFocusStyle.highlight`), given the card's measured size and
        /// how far its outline used to reach *beyond* that size.
        ///
        /// The rule is "no smaller than before": with the outline gone, the card
        /// has to cover at least the ground the outlined card covered, outline
        /// included. So the ordinary focus scale is multiplied by how much the
        /// outline grew the card — per axis, taking whichever axis the outline
        /// grew more (a short card's outline is proportionally a bigger share of
        /// its height than of its width), so the enlarged card is at least as
        /// large in *both* directions.
        ///
        /// - Parameters:
        ///   - outlineScale: the scale this card uses in the outlined style.
        ///   - contentSize: the card's own (unscaled) layout size.
        ///   - outlineReach: how far the outline extended past that size on each
        ///     edge — the halo's padding for artwork-only cards, the glass
        ///     frame's inset for framed ones.
        public static func highlightFocusScale(
            outlineScale: CGFloat,
            contentSize: CGSize,
            outlineReach: CGFloat
        ) -> CGFloat {
            // A caller asking for no lift at all (Reduce Motion) must not be
            // handed one by the multiplier.
            guard outlineScale > 1 else { return outlineScale }
            // No reach means no ground to grow back. A framed card's glass frame
            // lives inside its own bounds, so when it stops lighting up the card
            // has lost nothing and must keep exactly the scale it always had.
            //
            // This is a `return`, not a fall-through to the fallback below: zero
            // reach is a complete answer, and treating it as "unmeasured" grew
            // every framed card by the fallback ratio — which is precisely the
            // "framed cards are too big" this was meant to fix.
            guard outlineReach > 0 else { return outlineScale }
            // Reach, but no size yet: the frame or two before a card is measured.
            guard contentSize.width > 0, contentSize.height > 0 else {
                return outlineScale * highlightFocusFallbackRatio
            }
            let ratio = max(
                (contentSize.width + outlineReach * 2) / contentSize.width,
                (contentSize.height + outlineReach * 2) / contentSize.height
            )
            return outlineScale * min(max(ratio, 1), highlightFocusMaxRatio)
        }

        /// Growth used for the frame or two before a card has been measured, and
        /// for anything that can't be. Sized from the *smallest* card in the app
        /// (a cast portrait), whose outline is proportionally the largest, so the
        /// "no smaller than before" rule holds everywhere on the fallback too.
        public static let highlightFocusFallbackRatio: CGFloat = 1.11
        /// Ceiling on that growth, so a small or oddly-shaped card can't be
        /// blown up into its neighbours.
        public static let highlightFocusMaxRatio: CGFloat = 1.22

        /// Duration of the specular sweep that crosses a card as it takes focus.
        public static let highlightSheenDuration: TimeInterval = 0.85

        /// The focus animation for a card, which is where the two styles differ
        /// most: the outlined card cross-fades a surface, so a short ease is all
        /// it needs, while the highlighted card is pure movement and reads as
        /// physical — it springs up with a little life, and eases back down more
        /// slowly than it came, so leaving a card looks like it settling rather
        /// than snapping off.
        public static func cardFocusAnimation(
            isFocused: Bool,
            focusStyle: CardFocusStyle,
            reduceMotion: Bool
        ) -> Animation {
            guard focusStyle == .highlight, !reduceMotion else {
                return .easeOut(duration: 0.18)
            }
            return isFocused
                ? .spring(response: 0.30, dampingFraction: 0.66)
                : .spring(response: 0.52, dampingFraction: 0.82)
        }

        /// How long a card keeps its raised z-position after losing focus, so the
        /// slower settle finishes *above* its neighbours instead of being clipped
        /// behind the card that just took focus.
        public static let highlightSettleDuration: TimeInterval = 0.52

        /// How much further a focused card's caption drops in the highlight style.
        ///
        /// The push exists to keep a growing card off its own title, so it has to
        /// track how much the card actually grows. Highlight grows roughly twice
        /// as far past its resting size as the outlined style does, so the caption
        /// has to get out of the way by roughly twice as much or the card lands on
        /// top of it. Expressed as a ratio rather than a second constant, so the
        /// two can't drift apart when the scales are tuned.
        public static let highlightCaptionPushRatio: CGFloat = 1.85

        /// How far a card tips as focus arrives on it, before unwinding flat.
        ///
        /// Small on purpose. This is meant to read as the card having mass — it
        /// took the push that moved focus — not as an animation playing. Past a
        /// few degrees it stops looking like weight and starts looking like a
        /// trick, and a trick is exactly the thing that gets old.
        public static let highlightLeanDegrees: Double = 5

        /// Perspective for that tip. Shallow: a strong perspective on a card the
        /// size of a poster distorts it into a shape the artwork was never
        /// composed for.
        public static let highlightLeanPerspective: CGFloat = 0.55

        // MARK: Card captions

        /// How long a caption's dissolve is, as a multiple of the caption inset
        /// it lives in.
        ///
        /// A multiple rather than a fixed width, because that inset is already
        /// derived per card — poster and landscape have different corner radii,
        /// and every radius moves with the display-size setting — so expressing
        /// the fade this way makes it track every card variation and density on
        /// its own. At standard density the inset is 10–12pt, so a 1:1 fade was
        /// about a third of a character wide: technically a gradient, visually a
        /// cut.
        ///
        /// One value for every state, deliberately. A fade that lengthened on
        /// focus changed where the line began dissolving, which changed how much
        /// of it fitted, which changed whether it was masked at all — and a mask
        /// that appears when a card takes focus stops the caption animating (see
        /// `PlozzMarqueeText.EdgeFade`). Focus decides whether the line walks;
        /// it decides nothing about the line's geometry.
        public static let marqueeFadeRatio: CGFloat = 2.2

        /// How fast a focused card's caption walks its overflow into view.
        ///
        /// Reading pace, not scrolling pace — and unhurried, because the line is
        /// going to sit at the far end for a second anyway. Fast enough that a
        /// long title finishes before you've moved on, slow enough that the
        /// movement itself is calm.
        public static let marqueePointsPerSecond: Double = 32
        /// How fast it glides back afterwards. A little quicker than the way out:
        /// the return carries no information — you've already read the end — so
        /// it shouldn't take as long, but it still has to feel like the same
        /// movement, not a snap.
        public static let marqueeReturnPointsPerSecond: Double = 46
        /// How long a caption sits still after taking focus before it starts to
        /// move — long enough to read the beginning first, and long enough that
        /// scrubbing through a row never sets anything moving.
        public static let marqueeStartDelay: Double = 1.0
        /// How long the end of the line stays on screen once it arrives. Without
        /// this the title's end is only ever glimpsed in passing.
        public static let marqueeEndHold: Double = 1.4
        /// How long it rests at the start before going again, so a card left in
        /// focus isn't in perpetual motion.
        public static let marqueeRestHold: Double = 1.2

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

        /// Base leg length of the "unwatched" corner flag (the right-triangle in a
        /// card's top-trailing corner). Density-scaled (with a floor at
        /// `unwatchedFlagMinSize`) in `PlozzMetrics`, so the flag grows/shrinks
        /// with the display-size setting like the rest of the card instead of
        /// staying a fixed pixel size.
        public static let unwatchedFlagSize: CGFloat = 56
        /// Smallest the density-scaled unwatched flag is allowed to get, so it
        /// stays clearly visible even on the tiniest (micro-density) cards.
        public static let unwatchedFlagMinSize: CGFloat = 42

        /// Base diameter of the "watched" check badge (the circle in a card's
        /// top-trailing corner). Density-scaled (with a floor at
        /// `watchedBadgeMinSize`) in `PlozzMetrics`, so — like the unwatched flag
        /// and progress bar — it grows/shrinks with the display-size setting
        /// instead of staying a fixed pixel size. Nudged a little larger than its
        /// former fixed 38pt so it reads better on large cards.
        public static let watchedBadgeSize: CGFloat = 42
        /// Smallest the density-scaled watched badge is allowed to get, so the
        /// check stays legible on the tiniest (micro-density) cards.
        public static let watchedBadgeMinSize: CGFloat = 36

        // MARK: Detail

        /// Leading inset for the detail hero's title/metadata block, shared by the
        /// rows beneath it (seasons, episodes, cast, chips) so the whole page lines
        /// up on one edge. Tracks `screenPadding` (the shared screen-edge inset, now
        /// deferring to the system safe area) so detail and Home content sit on the
        /// same left edge.
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
