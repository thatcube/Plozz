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
    /// Artwork width for a Continue Watching card.
    ///
    /// Narrower than an ordinary landscape card because it is taller (see
    /// ``ContinueWatchingCardShape/widthScale``) — but unlike every other card
    /// size it also grows with **Dynamic Type**.
    ///
    /// It has to. This card carries its text *inside* the artwork ("S1, E12 ·
    /// 17m", on one line, beside a play glyph and a progress bar) rather than in
    /// a caption underneath that can wrap or grow. The text tracks the reader's
    /// chosen size while a density-scaled card does not, so at a large text size
    /// the label simply ran out of card and truncated to "S1, E1 · 4…" — the
    /// episode you are being told about, cut off. A card whose contents are fixed
    /// to the text they hold has to be sized by that text.
    public let continueWatchingWidth: CGFloat
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
    ///
    /// Use ``focusCaptionPush(for:)`` at any call site that knows the focus
    /// style — how far a card grows depends on it, and so does how far its
    /// caption has to move to stay clear.
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

    /// Diameter of the "watched" check badge, density-scaled and floored at
    /// `PlozzTheme.Metrics.watchedBadgeMinSize` so it grows with the display-size
    /// setting (like the unwatched flag) yet never shrinks below a legible minimum.
    public let watchedBadgeSize: CGFloat

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
    /// Artwork status-cue typography and insets. These scale with card density but
    /// retain explicit floors so compact poster walls never make the cue illegible.
    public let cardStatusCueFontSize: CGFloat
    public let cardStatusCueHorizontalPadding: CGFloat
    public let cardStatusCueVerticalPadding: CGFloat
    /// Resume-chip metrics — the play glyph + progress bar + "… left" line drawn
    /// on landscape artwork (Continue Watching cards and episode cards on every
    /// platform). Sized per-platform: tvOS uses its tuned 10-foot constants, iOS
    /// derives from real text styles so it tracks Dynamic Type natively.
    public let resumeChipFontSize: CGFloat
    public let resumeChipInset: CGFloat
    public let resumeChipBarWidth: CGFloat
    public let resumeChipBarHeight: CGFloat
    /// Edge length of the trailing accessory (download state) on a resume chip.
    public let resumeChipAccessorySize: CGFloat
    /// Height of the resume progress bar inside a hero Play button.
    ///
    /// Bigger than the card chip's bar — a hero button is a much larger target
    /// carrying much larger type — and, like it, grown on a damped curve as the
    /// reader's text size goes up. Without that it stayed a hairline under a
    /// button whose label had doubled.
    public let heroProgressBarHeight: CGFloat
    /// Artwork "…" menu: glyph size, tap-target edge, and inset from the artwork
    /// edge. Sized as a CONTROL (finger/remote), not to match nearby text — which
    /// is why it doesn't ride `resumeChipAccessorySize`.
    public let artworkMenuGlyphSize: CGFloat
    public let artworkMenuTargetSize: CGFloat
    public let artworkMenuInset: CGFloat
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

    /// How far a focused tile's caption drops, for the focus style in use.
    ///
    /// The push is only ever there to keep a growing card off its own title, so
    /// it has to follow how far the card actually grows: the highlight style
    /// grows about twice as far past its resting size as the outlined one, and a
    /// caption that stays put gets sat on. The reserved gap slot and the caption's
    /// own offset must both come from here, or the card's footprint changes with
    /// focus and the whole row shifts.
    public func focusCaptionPush(for focusStyle: CardFocusStyle) -> CGFloat {
        guard !focusStyle.drawsFocusOutline else { return focusCaptionPush }
        return (focusCaptionPush * PlozzTheme.Metrics.highlightCaptionPushRatio).rounded()
    }

    /// Exact rail footprint for a shared media card. Home uses this instead of a
    /// separate iOS width table so the slot can never be wider than the rendered
    /// surface and create invisible inter-card spacing.
    public func cardSlotWidth(
        for style: PosterCardView.Style,
        cardStyle: CardStyle,
        showsSeriesArtwork: Bool = false
    ) -> CGFloat {
        let artworkWidth = switch style {
        case .poster: posterWidth
        case .landscape: showsSeriesArtwork ? continueWatchingWidth : landscapeWidth
        }
        let sideInset = switch cardStyle {
        case .framed: cardInset
        case .borderless: borderlessCardSideMargin
        }
        return artworkWidth + sideInset * 2
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

    /// - Parameter dynamicTypeSize: the reader's current text size. Pass the
    ///   view's `\.dynamicTypeSize` so the metrics REBUILD when it changes —
    ///   typography here is sampled once at construction, so without that
    ///   dependency the whole table stays frozen at whatever the size was on
    ///   launch and a text-size change only takes effect on relaunch.
    public init(density: UIDensity, dynamicTypeSize: DynamicTypeSize = .large) {
        self.init(density: density, geometryScale: 1, dynamicTypeSize: dynamicTypeSize)
    }

    /// Touch-sized geometry for the shared card system. Typography still follows
    /// the platform's native Dynamic Type metrics; only physical card geometry,
    /// insets, overlays, and spacing are reduced from the 10-foot tvOS scale.
    public static func touch(
        density: UIDensity,
        dynamicTypeSize: DynamicTypeSize = .large
    ) -> PlozzMetrics {
        PlozzMetrics(density: density, geometryScale: 0.5, dynamicTypeSize: dynamicTypeSize)
    }

    private init(density: UIDensity, geometryScale: CGFloat, dynamicTypeSize: DynamicTypeSize) {
        let densityScale = CGFloat(density.scale)
        let s = densityScale * geometryScale
        self.density = density
        self.scale = densityScale

        #if canImport(UIKit)
        // Resolve typography against the size we were HANDED rather than whatever
        // the process-wide trait collection happens to hold. Two reasons: the
        // caller's `\.dynamicTypeSize` is the value SwiftUI actually invalidates
        // on, and sampling a global would silently disagree with it in previews,
        // on a secondary scene, or mid-transition.
        let typeTraits = UITraitCollection(
            preferredContentSizeCategory: dynamicTypeSize.plozzContentSizeCategory
        )
        func scaled(_ style: UIFont.TextStyle, _ base: CGFloat) -> CGFloat {
            UIFontMetrics(forTextStyle: style).scaledValue(for: base, compatibleWith: typeTraits)
        }
        func preferred(_ style: UIFont.TextStyle) -> CGFloat {
            UIFont.preferredFont(forTextStyle: style, compatibleWith: typeTraits).pointSize
        }
        #endif

        func step(_ base: CGFloat) -> CGFloat { (base * s).rounded() }        /// Like `step`, but only applies `damping` of the density deviation from
        /// 1.0 — so `damping: 1` behaves exactly like `step`, `damping: 0` stays
        /// fixed at the base, and values between let an element nod to density
        /// without scaling 1:1 with the cards.
        func damped(_ base: CGFloat, _ damping: CGFloat) -> CGFloat {
            let effectiveScale = 1 + (densityScale - 1) * damping
            return (base * effectiveScale).rounded()
        }

        // Card sizes derive from the standard-density constants in PlozzTheme.
        self.posterWidth = step(PlozzTheme.Metrics.posterWidth)
        self.posterHeight = step(PlozzTheme.Metrics.posterHeight)
        self.landscapeWidth = step(PlozzTheme.Metrics.landscapeWidth)
        self.landscapeHeight = step(PlozzTheme.Metrics.landscapeHeight)

        // How much bigger the reader has asked the chip's text style to be. 1 at
        // the default size on every platform, so nothing below changes until
        // someone actually turns text up.
        let chipTypeGrowth: CGFloat
        #if canImport(UIKit)
        chipTypeGrowth = scaled(.subheadline, 100) / 100
        #else
        chipTypeGrowth = 1
        #endif
        // Damped and capped rather than followed 1:1. The chip is not all text —
        // its inset, play glyph and progress bar are fixed — so matching the type
        // growth exactly would over-widen the card, and at the accessibility sizes
        // it would run past the width of a phone. Past the cap the text scales
        // itself down instead (see `ResumeChipOverlay`), which keeps the label
        // whole; growing the card is what stops that being necessary for the
        // ordinary large sizes people actually use.
        let cardTypeGrowth = min(1.6, max(1, 1 + (chipTypeGrowth - 1) * 0.75))
        self.continueWatchingWidth = (
            self.landscapeWidth * ContinueWatchingCardShape.widthScale * cardTypeGrowth
        ).rounded()
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
        self.watchedBadgeSize = max(
            step(PlozzTheme.Metrics.watchedBadgeSize),
            PlozzTheme.Metrics.watchedBadgeMinSize
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

        // Caption fonts scale with density AND with the reader's text size.
        //
        // The title's base is the live platform `.subheadline` size, so it has
        // always tracked Dynamic Type. The subtitle multiplied a hard-coded
        // constant instead, so a card's metadata line ("2022 · 45m left") stayed
        // the same size no matter how large the reader set their text — the title
        // above it grew and the line under it didn't.
        //
        // `UIFontMetrics.scaledValue(for:)` fixes that without changing how
        // anything looks today: at the default content size it returns the base
        // unchanged, so standard density on both platforms is byte-identical, and
        // it grows on the `.subheadline` curve from there — the same curve the
        // title already follows.
        #if os(tvOS)
        let baseTitleFontSize = preferred(.subheadline)
        // tvOS keeps its own tuned constant (20 against a 29pt title), scaled on
        // the same curve as the title so it tracks the reader's text size.
        let baseSubtitleFontSize = scaled(.subheadline, PlozzTheme.Metrics.cardSubtitleFontSize)
        #elseif canImport(UIKit)
        let baseTitleFontSize = preferred(.subheadline)
        // iOS/iPadOS: one step BELOW the title. `cardSubtitleFontSize` is a tvOS
        // value (20 reads as secondary against a 29pt title) and applying it here
        // made the metadata line 20pt against a 15pt title — the caption was
        // literally larger than the title it described. `.footnote` sits directly
        // under `.subheadline`, restoring the hierarchy, and being a real text
        // style it tracks Dynamic Type natively.
        let baseSubtitleFontSize = preferred(.footnote)
        #else
        let baseTitleFontSize = PlozzTheme.Metrics.cardTitleFontSizeFallback
        let baseSubtitleFontSize = PlozzTheme.Metrics.cardSubtitleFontSize
        #endif
        self.cardTitleFontSize = (baseTitleFontSize * densityScale).rounded()
        self.cardSubtitleFontSize = (baseSubtitleFontSize * densityScale).rounded()

        // Resume chip. iOS/iPadOS derives from `.subheadline` so the chip sits with
        // the card's own typography, rather than inheriting tvOS point sizes (which
        // read as enormous on a handset — the same trap the card caption fell into).
        //
        // tvOS keeps its tuned 10-foot constants as the BASE and scales them on the
        // `.subheadline` curve, the same way the tvOS card subtitle already does.
        // `UIFontMetrics` is fully available on tvOS (`tvos(11.0)`), and at the
        // default content size `scaledValue(for:)` returns the base unchanged.
        //
        // The bar is the exception on BOTH platforms: its tuned size is kept at
        // the default text size and only ever scaled UP from there — see
        // `barTypeScale`.
        #if os(tvOS)
        let baseChipFont = scaled(.subheadline, PlozzTheme.Metrics.resumeChipFontSize)
        let baseChipInset = scaled(.subheadline, PlozzTheme.Metrics.resumeChipInset)
        let barScale = barTypeScale(scaled(.subheadline, 100) / 100)
        let baseChipBarWidth = PlozzTheme.Metrics.resumeChipBarWidth * barScale
        let baseChipBarHeight = PlozzTheme.Metrics.resumeChipBarHeight * barScale
        let baseChipAccessory = scaled(.subheadline, PlozzTheme.Metrics.resumeChipAccessorySize)
        #elseif canImport(UIKit)
        let baseChipFont = preferred(.subheadline)
        let baseChipInset: CGFloat = 12
        let barScale = barTypeScale(scaled(.subheadline, 100) / 100)
        // 38 × 6 at the default text size, exactly as they were tuned.
        let baseChipBarWidth = 38 * barScale
        let baseChipBarHeight = 6 * barScale
        // Matches the chip's cap height closely enough to sit on the same baseline.
        let baseChipAccessory = preferred(.subheadline) + 6
        #else
        let baseChipFont = PlozzTheme.Metrics.resumeChipFontSize
        let baseChipInset = PlozzTheme.Metrics.resumeChipInset
        let baseChipBarWidth = PlozzTheme.Metrics.resumeChipBarWidth
        let baseChipBarHeight = PlozzTheme.Metrics.resumeChipBarHeight
        let baseChipAccessory = PlozzTheme.Metrics.resumeChipAccessorySize
        #endif
        self.resumeChipFontSize = (baseChipFont * densityScale).rounded()
        self.resumeChipInset = (baseChipInset * densityScale).rounded()
        self.resumeChipBarWidth = (baseChipBarWidth * densityScale).rounded()
        // Floored: a sub-pixel bar disappears entirely at micro density.
        self.resumeChipBarHeight = max((baseChipBarHeight * densityScale).rounded(), 3)
        self.resumeChipAccessorySize = (baseChipAccessory * densityScale).rounded()
        // Hero Play button bar. Same rule: the tuned height at the default text
        // size, scaled up only as the reader's text grows.
        #if os(tvOS)
        let heroBarBase: CGFloat = 10
        #else
        let heroBarBase: CGFloat = 6
        #endif
        #if canImport(UIKit)
        let heroBarScale = barTypeScale(scaled(.subheadline, 100) / 100)
        #else
        let heroBarScale: CGFloat = 1
        #endif
        self.heroProgressBarHeight = max(
            (heroBarBase * heroBarScale * densityScale).rounded(),
            3
        )

        // Same treatment for the artwork "…" affordance: tuned tvOS constants as the
        // base, scaled on the `.headline` curve the iOS branch below already uses.
        #if os(tvOS)
        let baseMenuGlyph = scaled(.headline, PlozzTheme.Metrics.artworkMenuGlyphSize)
        let baseMenuTarget = scaled(.headline, PlozzTheme.Metrics.artworkMenuTargetSize)
        #elseif canImport(UIKit)
        // Match the episode rows' existing, proven affordance: a bold `.headline`
        // glyph in a 44pt target.
        let baseMenuGlyph = preferred(.headline)
        let baseMenuTarget: CGFloat = 44
        #else
        let baseMenuGlyph = PlozzTheme.Metrics.artworkMenuGlyphSize
        let baseMenuTarget = PlozzTheme.Metrics.artworkMenuTargetSize
        #endif
        self.artworkMenuGlyphSize = (baseMenuGlyph * densityScale).rounded()
        // Floored at 44: density must never shrink a control below the comfortable
        // touch minimum.
        self.artworkMenuTargetSize = max((baseMenuTarget * densityScale).rounded(), 44)
        self.artworkMenuInset = (PlozzTheme.Metrics.artworkMenuInset * densityScale).rounded()
        #if os(tvOS)
        let statusCueFont = PlozzTheme.Metrics.cardStatusCueFontSize
        let statusCueMinFont = PlozzTheme.Metrics.cardStatusCueMinFontSize
        let statusCueHorizontalPadding = PlozzTheme.Metrics.cardStatusCueHorizontalPadding
        let statusCueMinHorizontalPadding =
            PlozzTheme.Metrics.cardStatusCueMinHorizontalPadding
        let statusCueVerticalPadding = PlozzTheme.Metrics.cardStatusCueVerticalPadding
        let statusCueMinVerticalPadding = PlozzTheme.Metrics.cardStatusCueMinVerticalPadding
        #elseif canImport(UIKit)
        let statusCueFont = preferred(.caption2)
        let statusCueMinFont = PlozzTheme.Metrics.cardStatusCueTouchMinFontSize
        let statusCueHorizontalPadding = scaled(
            .caption2,
            PlozzTheme.Metrics.cardStatusCueTouchHorizontalPadding
        )
        let statusCueMinHorizontalPadding =
            PlozzTheme.Metrics.cardStatusCueTouchMinHorizontalPadding
        let statusCueVerticalPadding = scaled(
            .caption2,
            PlozzTheme.Metrics.cardStatusCueTouchVerticalPadding
        )
        let statusCueMinVerticalPadding =
            PlozzTheme.Metrics.cardStatusCueTouchMinVerticalPadding
        #else
        let statusCueFont = PlozzTheme.Metrics.cardStatusCueFontSize
        let statusCueMinFont = PlozzTheme.Metrics.cardStatusCueMinFontSize
        let statusCueHorizontalPadding = PlozzTheme.Metrics.cardStatusCueHorizontalPadding
        let statusCueMinHorizontalPadding =
            PlozzTheme.Metrics.cardStatusCueMinHorizontalPadding
        let statusCueVerticalPadding = PlozzTheme.Metrics.cardStatusCueVerticalPadding
        let statusCueMinVerticalPadding = PlozzTheme.Metrics.cardStatusCueMinVerticalPadding
        #endif
        self.cardStatusCueFontSize = max(
            (statusCueFont * densityScale).rounded(),
            statusCueMinFont
        )
        self.cardStatusCueHorizontalPadding = max(
            (statusCueHorizontalPadding * densityScale).rounded(),
            statusCueMinHorizontalPadding
        )
        self.cardStatusCueVerticalPadding = max(
            (statusCueVerticalPadding * densityScale).rounded(),
            statusCueMinVerticalPadding
        )
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

#if canImport(UIKit)
extension DynamicTypeSize {
    /// The UIKit content-size category matching this SwiftUI size.
    ///
    /// `PlozzMetrics` resolves typography through `UIFontMetrics`, which is a
    /// UIKit API, while the value SwiftUI invalidates views on is
    /// `\.dynamicTypeSize`. Mapping across explicitly keeps the two in agreement
    /// instead of letting the metrics read a process-wide category that SwiftUI
    /// never told them about.
    var plozzContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
/// How much a progress bar grows for a given growth in the reader's text size.
///
/// Returns **exactly 1 at the default text size**, which is the important part:
/// the tuned bar sizes are right as they are, and were never the complaint. The
/// bar only looked short when the text around it had grown and it had not, so
/// this only ever scales *up* from a size that is already correct.
///
/// Damped and capped rather than tracking the type curve: a bar that matched it
/// 1:1 became a slab and the loudest thing on the card. It is applied to both
/// dimensions, since a bar that grew only in height would go from short to
/// stubby.
///
/// Width growth is safe here only because the bar is flexible where it shares a
/// line with a label (see `ResumeProgressCapsule.flexesToFitRow`): this is a
/// ceiling it may reach, not a width it insists on, so a long label still takes
/// what it needs first.
private func barTypeScale(_ typeGrowth: CGFloat) -> CGFloat {
    min(1.7, 1 + (max(1, typeGrowth) - 1) * 0.5)
}
#endif
