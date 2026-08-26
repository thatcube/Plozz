#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import MetadataKit

/// A focusable poster/landscape card for a `MediaItem`, with artwork, a watched
/// progress bar, and title/subtitle. The standard building block of Home rows
/// and library grids.
///
/// Both styles drive focus through a plain `.focusable` view (never a `Button`,
/// whose tvOS focus *platter* paints a stark white plate over our glass) plus an
/// `.onTapGesture` select handler. The focus visual is entirely our own
/// Twozz-ported liquid-glass lift: a theme-tinted glass surface with a
/// focused-only drop shadow and a series-aware title treatment for episodes.
public struct PosterCardView: View {
    public enum Style { case poster, landscape }

    private let item: MediaItem
    private let style: Style
    private let spoilerSettings: SpoilerSettings
    /// Identify the card by its **show** — the show's wide artwork with its logo
    /// laid over it — instead of by the item's own thumbnail. Used by Continue
    /// Watching, where the row is one entry per show and telling the shows apart
    /// at a glance is the whole job of the card.
    private let showsSeriesArtwork: Bool
    private let enablesAsyncArtworkFallback: Bool
    private let reservesSubtitleSpace: Bool
    /// Optional caller-owned context cue. It occupies the artwork's top-leading
    /// slot, leaving watch state (top-trailing) and progress (bottom) untouched.
    ///
    /// This is app copy, not media metadata, so it is a `LocalizedStringResource`
    /// rather than a `String` — a plain `String` reaching `Text` renders verbatim
    /// and would silently stay English. Media titles on this same card stay
    /// `String` on purpose; they are provider content and must not be translated.
    private let statusCueText: LocalizedStringResource?
    /// When `true`, selecting the card starts playback immediately (Continue
    /// Watching, landscape library rows) rather than opening a detail page. Such
    /// cards show the resume chip — play glyph + progress bar + time-remaining —
    /// over a soft bottom-leading scrim, matching the episode card.
    private let playsOnSelect: Bool
    /// Forces the resume chip on regardless of `playsOnSelect`, and supplies the
    /// download affordance. Needed because the chip and the tap behaviour are
    /// separate concerns: iOS/iPadOS Continue Watching cards open a detail page
    /// (so `playsOnSelect` is false) but must still SHOW resume progress — which
    /// is exactly why that treatment was missing on iOS while tvOS had it.
    private let showsResumeChipOverride: Bool
    private let downloadState: MediaDownloadBadgeState?
    /// Draws the visible "…" actions menu on the artwork. Touch surfaces opt in;
    /// tvOS leaves it off because press-and-hold is already discoverable there.
    private let showsActionsMenu: Bool
    private let action: () -> Void

    @FocusState private var isFocused: Bool
    /// This card's resolved logo tone, and the tone of the artwork it sits on.
    /// Together they decide how far the artwork is dimmed behind it — see
    /// ``ContinueWatchingCardShape/artworkDim(logo:background:)``. Either being
    /// `nil` (still resolving, or a card with no logo) simply means the base dim.
    /// Whether the artwork this card ended up with already has the show's name
    /// printed on it, in which case the card must not print it again.
    @State private var artworkAlreadyCarriesTitle = false
    /// Bumped once this show's artwork source is settled (or the wait for it ran
    /// out), which is what lets the body re-read the synchronous store.
    @State private var textlessAnswerRevision = 0
    @State private var logoTone: ResolvedLogoTone?
    @State private var artworkTone: HeroBackgroundSample?
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzMetrics) private var metrics
    /// Per-profile card presentation (framed glass card vs borderless artwork).
    @Environment(\.plozzCardStyle) private var cardStyle
    /// Per-profile focus treatment. With the outline off, a framed card keeps its
    /// resting surface on focus (no glass lift, so no glowing frame) and reads as
    /// focused through movement and light instead — see `plozzCardFocusLift`.
    @Environment(\.plozzCardFocusStyle) private var focusStyle

    public init(
        item: MediaItem,
        style: Style = .poster,
        spoilerSettings: SpoilerSettings = .default,
        showsSeriesArtwork: Bool = false,
        enablesAsyncArtworkFallback: Bool = true,
        reservesSubtitleSpace: Bool = true,
        statusCue: LocalizedStringResource? = nil,
        playsOnSelect: Bool = false,
        showsResumeChip: Bool = false,
        downloadState: MediaDownloadBadgeState? = nil,
        showsActionsMenu: Bool = false,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.style = style
        self.spoilerSettings = spoilerSettings
        self.showsSeriesArtwork = showsSeriesArtwork
        self.enablesAsyncArtworkFallback = enablesAsyncArtworkFallback
        self.reservesSubtitleSpace = reservesSubtitleSpace
        self.statusCueText = statusCue
        self.playsOnSelect = playsOnSelect
        self.showsResumeChipOverride = showsResumeChip
        self.downloadState = downloadState
        self.showsActionsMenu = showsActionsMenu
        self.action = action
    }

    /// Spoiler masking never applies in series-artwork mode: the card carries the
    /// show's own art and its logo, so there is no episode frame on it to hide.
    /// Blurring or replacing it would only obscure the show's identity.
    private var hideThumbnail: Bool {
        !showsSeriesArtwork && spoilerSettings.shouldHideThumbnail(for: item)
    }

    /// A poster-shaped episode card is masked by *narrowing its sources*, not by
    /// blurring what it drew.
    ///
    /// Such a card never carries the episode's own frame to begin with: poster
    /// style resolves an episode through the `.seriesPoster` placement, which is
    /// the show's poster — the same image the series' own card uses, identical for
    /// every episode of that show. Blurring it hid nothing and cost the viewer the
    /// one thing a Recently Added row exists to say: which show this is.
    ///
    /// The single leak in that ladder is its `posterURL` last resort (on Jellyfin
    /// the episode's own primary image), so the card draws
    /// ``placeholderArtworkReferences`` instead — the series-only ladder — and
    /// draws it sharp. Landscape and episode-column cards are NOT included: those
    /// paint `.episodeThumbnail`, which really is the still, and keep their mask.
    private var showsSpoilerSafePoster: Bool {
        hideThumbnail && style == .poster && item.kind == .episode
    }
    private var hideText: Bool { spoilerSettings.shouldHideText(for: item) }

    /// Whether the card's **surface** should read as focused. The glass lift is
    /// the framed card's focus outline, so with the outline turned off the
    /// surface stays exactly as it is at rest and the caption keeps its resting
    /// ink — the lift's white plate is what made dark text legible, and there is
    /// no plate now.
    private var surfaceFocused: Bool { isFocused && focusStyle.drawsFocusOutline }

    /// Title/subtitle colour, flipped to dark ink over a focused card's opaque
    /// "lift" surface. Centralised in `PlozzCardCaption` so every card type flips
    /// identically.
    private var titleColor: Color {
        PlozzCardCaption.titleColor(isFocused: surfaceFocused, reduceTransparency: reduceTransparency)
    }
    private var subtitleColor: Color {
        PlozzCardCaption.subtitleColor(isFocused: surfaceFocused, reduceTransparency: reduceTransparency)
    }

    private var size: CGSize {
        switch style {
        case .poster:
            return CGSize(width: metrics.posterWidth, height: metrics.posterHeight)
        case .landscape:
            // A series-artwork card stands taller than the 16:9 art it carries so
            // its chrome has a band of its own beneath the picture, and is
            // narrower to keep that extra height from enlarging the whole rail.
            // See ``ExtendedArtworkFill``.
            guard showsSeriesArtwork else {
                return CGSize(width: metrics.landscapeWidth, height: metrics.landscapeHeight)
            }
            let width = metrics.continueWatchingWidth
            return CGSize(
                width: width,
                height: (width / ContinueWatchingCardShape.aspectRatio).rounded()
            )
        }
    }

    public var body: some View {
        cardBody
            // Hand this card's focus to the shared chrome drawn on its artwork
            // (progress bar, resume chip) so it settles at rest and comes to full
            // strength on focus. No-op off tvOS.
            .plozzChromeFocused(isFocused)
            .mediaItemContextMenu(for: item)
    }

    @ViewBuilder
    private var cardBody: some View {
        switch cardStyle {
        case .framed:
            switch style {
            case .poster:
                posterCard
            case .landscape:
                landscapeCard
            }
        case .borderless:
            borderlessCard
        }
    }

    // MARK: Poster

    private var posterCard: some View {
        VStack(alignment: .leading, spacing: metrics.posterCaptionTopSpacing) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { artwork }
                .overlay(alignment: .topLeading) { statusCue(inset: 8) }
                .overlay {
                    MediaCardPlaybackIndicators(
                        item: item,
                        hidesStatus: hideThumbnail,
                        showsProgressBar: !showsResumeChip,
                        badgeInset: 8,
                        progressHeight: metrics.progressBarHeight,
                        progressHorizontalInset: 16,
                        progressBottomInset: 16,
                        downloadState: showsResumeChip ? nil : downloadState
                    )
                }
                .overlay { resumeChip }
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius)

            VStack(alignment: .leading, spacing: 2) {
                primaryText
                    .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                subtitleLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .bottom], metrics.posterCaptionInset)
        }
        .plozzFramedMediaCard(
            innerCornerRadius: PlozzTheme.Metrics.posterArtCornerRadius,
            isFocused: surfaceFocused
        )
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.posterCardCornerRadius, action: action)
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
        // Resting posters carry a soft drop shadow so they read as raised cards
        // (essential in Light mode against a white background); the focused card
        // deepens it. Resting cards now wear the cheap frosted `.ultraThinMaterial`
        // (no live-glass per-frame cost), so the surface returns without the scroll
        // lag that a live resting `.glassEffect` caused.
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0.15), radius: isFocused ? 20 : 8, y: isFocused ? 10 : 4)
        .plozzCardFocusLift(
            isFocused: isFocused,
            cornerRadius: metrics.posterCardCornerRadius,
            outlineScale: PlozzTheme.Metrics.focusedCardScale
        )
        .plozzCardFocusTransition(isFocused: isFocused)
    }

    // MARK: Landscape (medium) card

    private var landscapeCard: some View {
        VStack(alignment: .leading, spacing: metrics.landscapeCaptionTopSpacing) {
            artwork
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) { statusCue(inset: 8) }
                .overlay {
                    MediaCardPlaybackIndicators(
                        item: item,
                        hidesStatus: hideThumbnail,
                        showsProgressBar: !showsResumeChip,
                        badgeInset: 8,
                        progressHeight: metrics.progressBarHeight,
                        progressHorizontalInset: 16,
                        progressBottomInset: 16,
                        downloadState: showsResumeChip ? nil : downloadState
                    )
                }
                .overlay { resumeChip }
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius)

            // Series-artwork cards say everything on the artwork itself — the show
            // as its logo, the episode and time in the chip — so there is no
            // caption under them at all. A card that is purely its art is the
            // point of the treatment; a reserved-but-empty caption slot would just
            // read as a rendering bug.
            if !showsSeriesArtwork {
                VStack(alignment: .leading, spacing: 4) {
                    primaryText
                        .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    subtitleLine
                }
                .padding([.horizontal, .bottom], metrics.landscapeCaptionInset)
                .frame(width: size.width, alignment: .leading)
            }
        }
        .plozzFramedMediaCard(
            innerCornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
            isFocused: surfaceFocused
        )
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.landscapeCardCornerRadius, action: action)
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0.15), radius: isFocused ? 20 : 8, y: isFocused ? 10 : 4)
        .plozzCardFocusLift(
            isFocused: isFocused,
            cornerRadius: metrics.landscapeCardCornerRadius,
            outlineScale: PlozzTheme.Metrics.mediumFocusedCardScale
        )
        .plozzCardFocusTransition(isFocused: isFocused)
    }

    // MARK: Borderless (no card background)

    /// The "Posters" card style: no glass surface at all — just the artwork and
    /// its sub-text. The image fills the card slot (minus a small side margin that
    /// keeps cards separated), is rounded at the framed card's *outer* radius, and
    /// gains a crisp focus **outline** that hugs the artwork and scales with it on
    /// focus (plus a soft lift). The caption keeps the same horizontal clearance
    /// the framed caption uses, so text lines up with the artwork's rounded edge,
    /// and is pushed down while focused so the growing poster never crowds it.
    /// Shared by poster and landscape shapes — only aspect ratio, corner radius
    /// and focus scale differ.
    private var borderlessCard: some View {
        VStack(alignment: .leading, spacing: borderlessCaptionSpacing) {
            borderlessArtwork
            // See `landscapeCard`: a series-artwork card carries its text on the
            // artwork, so it has no caption.
            if !showsSeriesArtwork {
                BorderlessCardCaption(
                    title: primaryText,
                    subtitle: subtitleText,
                    horizontalInset: borderlessCaptionInset,
                    reservesSubtitleSpace: reservesSubtitleSpace
                )
                // Push the caption down on focus with a pure transform, never a layout
                // change: the gap slot is always reserved at its focused size (see
                // `borderlessCaptionSpacing`) and the caption rides *up* to the resting
                // gap when unfocused, dropping back down on focus. Because it's an
                // offset (like `scaleEffect`), the card's footprint is identical in both
                // states, so focusing one card can't shift the row or the page.
                .offset(y: isFocused ? 0 : -metrics.focusCaptionPush)
            }
        }
        .padding(.horizontal, metrics.borderlessCardSideMargin)
        .focusableCard(isFocused: $isFocused, cornerRadius: borderlessCornerRadius, action: action)
        // A borderless card's focus halo + scale bloom extend *beyond* the layout
        // bounds. `compositingGroup` composites them as one unit without clipping;
        // `drawingGroup` (what `plozzCardRasterize` uses under Reduce Transparency)
        // would rasterize to the layout bounds and shear off the halo + bloom.
        .compositingGroup()
        .plozzCardFocusTransition(isFocused: isFocused)
    }

    /// The full-bleed artwork for a borderless card, clipped to the outer radius
    /// with the shared focus outline + lift applied.
    private var borderlessArtwork: some View {
        Color.clear
            .aspectRatio(borderlessAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { artwork }
            .overlay(alignment: .topLeading) { statusCue(inset: borderlessBadgeInset) }
            .overlay {
                MediaCardPlaybackIndicators(
                    item: item,
                    hidesStatus: hideThumbnail,
                    showsProgressBar: !showsResumeChip,
                    badgeInset: borderlessBadgeInset,
                    progressHeight: metrics.progressBarHeight,
                    progressHorizontalInset: borderlessProgressInset,
                    progressBottomInset: borderlessProgressInset,
                    downloadState: showsResumeChip ? nil : downloadState
                )
            }
            .overlay { resumeChip }
            .clipShape(RoundedRectangle(cornerRadius: borderlessCornerRadius, style: .continuous))
            .plozzMediaEdge(cornerRadius: borderlessCornerRadius)
            .plozzFocusHalo(
                cornerRadius: borderlessCornerRadius,
                focusScale: borderlessFocusScale,
                isFocused: isFocused
            )
    }

    /// Artwork↔caption gap for a borderless card. The slot is **always** reserved
    /// at its focused size (base gap + the density-scaled focus push) so the card's
    /// footprint never changes with focus; the caption itself rides up to the base
    /// gap when unfocused via a transform offset (see `borderlessCard`). Reserving
    /// the larger gap here is what keeps the row/page from shifting when a card is
    /// focused, and gives the scaled-up poster room to clear its title.
    private var borderlessCaptionSpacing: CGFloat {
        let base: CGFloat
        switch style {
        case .poster: base = metrics.posterCaptionTopSpacing
        case .landscape: base = metrics.landscapeCaptionTopSpacing
        }
        return base + metrics.focusCaptionPush
    }

    /// Horizontal caption clearance for a borderless card — the same optical inset
    /// the framed caption uses for this shape, so text lines up with the rounded
    /// artwork edge instead of butting against it.
    private var borderlessCaptionInset: CGFloat {
        switch style {
        case .poster: return metrics.posterCaptionInset
        case .landscape: return metrics.landscapeCaptionInset
        }
    }

    @ViewBuilder
    private var subtitleLine: some View {
        if let subtitleText {
            Text(subtitleText)
                .font(.system(size: metrics.cardSubtitleFontSize))
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
        } else if reservesSubtitleSpace {
            Text(verbatim: " ")
                .font(.system(size: metrics.cardSubtitleFontSize))
                .hidden()
        }
    }

    /// Outer corner radius reused for a borderless image — the framed card's outer
    /// (glass) radius, so a borderless poster/landscape keeps the exact rounding
    /// the framed card's surface had.
    private var borderlessCornerRadius: CGFloat {
        switch style {
        case .poster: return metrics.posterCardCornerRadius
        case .landscape: return metrics.landscapeCardCornerRadius
        }
    }

    /// Even inset that keeps the borderless progress bar concentric with the card's
    /// rounded corner — the same inner/outer relationship the framed card's glass
    /// ring uses: an inner shape shares a corner's centre only when its inset equals
    /// `outerRadius − innerRadius`. The bar is a capsule (corner radius =
    /// `height / 2`), so this inset makes the gap even along the bottom edge *and*
    /// around both corners. It scales with density through the corner radius and the
    /// (scaled) bar height, and is floored so it never crowds the edge.
    private var borderlessProgressInset: CGFloat {
        max(borderlessCornerRadius - metrics.progressBarHeight / 2, 12)
    }

    /// Inset that keeps the watched badge concentric with the borderless card's
    /// rounded corner. The badge is a `metrics.watchedBadgeSize` circle, so its
    /// inset is `outerRadius − radius`, matching the progress bar's even spacing.
    private var borderlessBadgeInset: CGFloat {
        max(borderlessCornerRadius - metrics.watchedBadgeSize / 2, 8)
    }

    /// Aspect ratio for the borderless full-bleed image.
    private var borderlessAspectRatio: CGFloat {
        switch style {
        case .poster: return 2.0 / 3.0
        // Matches `size`: series-artwork cards are taller than their picture.
        case .landscape: return showsSeriesArtwork
            ? ContinueWatchingCardShape.aspectRatio
            : 16.0 / 9.0
        }
    }

    /// Focus lift for a borderless image — the shared tile focus scale
    /// (`mediumFocusedCardScale`), so borderless posters, landscape cards and the
    /// circular artist/cast tiles all zoom by the same amount on focus.
    private var borderlessFocusScale: CGFloat {
        PlozzTheme.Metrics.mediumFocusedCardScale
    }

    // MARK: Text

    /// Primary line. For episodes this is always the *series* title (never the
    /// episode's own name), which is both more useful in rails like Continue
    /// Watching and inherently spoiler-safe.
    ///
    /// `Text`, not `String`: the spoiler-hidden case is our own copy
    /// (`SpoilerSettings.maskedTitle`) while the other two cases are real
    /// (content) media titles rendered verbatim — mixing them into one `String`
    /// first would hide the copy from the catalog.
    private var primaryText: Text {
        // In series-artwork mode the artwork already carries the show's name — as
        // its logo, or as the styled text that stands in for one — so repeating it
        // here would say the same thing twice and leave the card silent about the
        // thing it hasn't said yet: which episode this is.
        if showsSeriesArtwork { return seriesArtworkCaption }
        if item.kind == .episode, let series = item.parentTitle, !series.isEmpty {
            return Text(verbatim: series)
        }
        if hideText { return Text(spoilerSettings.maskedTitle(for: item)) }
        return Text(verbatim: item.title)
    }

    /// The caption line for a card whose artwork carries the title.
    ///
    /// For an episode that is its place in the run — "S2 · E5". Note the guard on
    /// both numbers: `MediaItem.subtitle` falls back to the *series* title when it
    /// can't build a designation, which is exactly the string the logo is already
    /// showing, so we drop to the episode's own title instead (masked when spoiler
    /// protection is hiding episode text).
    private var seriesArtworkCaption: Text {
        if item.kind == .episode {
            if item.seasonNumber != nil,
               item.episodeNumber != nil,
               let designation = item.subtitle, !designation.isEmpty {
                return Text(verbatim: designation)
            }
            if hideText { return Text(spoilerSettings.maskedTitle(for: item)) }
            return Text(verbatim: item.title)
        }
        // A movie or series is the show, so its own title is on the artwork; the
        // caption carries the qualifier (a year) instead.
        guard let subtitle = item.subtitle, !subtitle.isEmpty else {
            return Text(verbatim: "")
        }
        return Text(verbatim: subtitle)
    }

    /// Secondary line — subtitle facts plus card runtime/remaining when available.
    /// The runtime/"… left" is dropped when the resume chip is shown, since the
    /// chip already carries the time on the artwork (no need to repeat it here).
    private var subtitleText: String? {  // l10n:content — composes CoreModels content (subtitle/runtime) with a "left" qualifier word; joined plain-String pipeline (see comment below), not a Text-rendered LSR
        var parts: [String] = []
        // Skipped in series-artwork mode: `subtitle` has been promoted to the
        // primary line there (see `primaryText`), and printing it in both places
        // would read as a stutter.
        if !showsSeriesArtwork,
           let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if !showsResumeChip,
           let runtime = item.cardRuntimeText?.trimmingCharacters(in: .whitespacesAndNewlines), !runtime.isEmpty {
            // `cardRuntimeText` is bare ("20m"); `subtitleText` is a plain String
            // joined with `·` and passed through `BorderlessCardCaption.subtitle`
            // (already `// l10n:content`, not a translated `Text`), so the "left"
            // suffix is composed here as plain interpolation rather than via
            // `String(localized:)`, which the guard flags as eager resolution.
            parts.append(item.cardRuntimeIsRemaining ? "\(runtime) left" : runtime)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    // MARK: Resume chip

    /// The full resume chip — ▶ + progress bar + time remaining — reserved for
    /// cards that start playback the moment they're selected (Continue Watching,
    /// landscape library rows), plus hosts that explicitly opt in.
    ///
    /// Browsing cards deliberately do NOT get it. A ▶ would promise instant
    /// playback they can't deliver, and the time text can't fit beside a download
    /// badge on a poster. They show the shared full-width progress bar instead
    /// (see ``MediaCardPlaybackIndicators``), which needs no runtime metadata — so
    /// every in-progress card looks the same whether or not its runtime is known.
    private var showsResumeChip: Bool {
        (playsOnSelect || showsResumeChipOverride)
            && !hideThumbnail
            // Resume progress qualifies on its own. Gating solely on runtime text
            // meant an item whose provider didn't supply a runtime dropped to the
            // plain full-width progress bar, so a Continue Watching row mixed the
            // two treatments depending on metadata the viewer can't see.
            && (item.cardRuntimeText != nil
                || item.resumeProgressFraction != nil
                || downloadState != nil
                || showsActionsMenu
                // A resumable item whose duration was never learned has NEITHER a
                // runtime nor a fraction — a share only learns one by playing the
                // file once, and a record written before that carries neither. The
                // item is still genuinely resumable, and dropping the chip left a
                // bare poster in Continue Watching: no progress, no play glyph and
                // no episode designation, next to the same episode's fully-dressed
                // card from another server.
                || item.resumePosition != nil
                // The designation alone is worth a chip on a series-artwork card,
                // where it is the only thing naming the episode. `ResumeChipOverlay`
                // already draws exactly this case (see its `hasBottomChrome`); this
                // outer gate simply never let it through.
                || (showsSeriesArtwork && item.seasonEpisodeLabel != nil))
    }

    /// The shared resume affordance — identical to the episode card's overlay.
    @ViewBuilder
    private var resumeChip: some View {
        if showsResumeChip {
            ResumeChipOverlay(
                item: item,
                downloadState: downloadState,
                showsMenu: showsActionsMenu,
                // Series-artwork cards carry the episode designation *in* the chip
                // rather than in a caption under the card, so one glance covers
                // which show (the logo), which episode, and how much is left.
                detailText: showsSeriesArtwork ? item.seasonEpisodeLabel : nil,
                showsPlayGlyphWhenIdle: showsSeriesArtwork,
                // A Continue Watching card darkens over a much longer run,
                // starting up in the picture and finishing lighter: it is not
                // working alone down there — the reflection lays down its own
                // wash — and the two compound. See ``ContinueWatchingCardShape``.
                bottomScrimStart: showsSeriesArtwork ? ContinueWatchingCardShape.scrimStart : nil,
                bottomScrimDepth: showsSeriesArtwork ? ContinueWatchingCardShape.scrimDepth : nil
            )
        }
    }

    // MARK: Artwork
    private var artworkReferences: [ArtworkReference] {
        switch style {
        case .poster:
            return item.artworkReferences(for: item.kind == .episode ? .seriesPoster : .poster)
        case .landscape:
            if item.kind == .episode {
                return item.artworkReferences(for: .episodeThumbnail)
            }
            // Local landscape/detail selections are explicit presentation candidates.
            // The remote rail order remains the long-standing backdrop → poster →
            // fallback sequence; a full-resolution hero must never jump the rail.
            let explicit = item.artworkSelections
                .first(where: { $0.placement == .detailBackdrop })?
                .references ?? []
            let legacy = [item.backdropURL, item.posterURL, item.fallbackArtworkURL]
                .compactMap { $0.map(ArtworkReference.remote) }
            var seen = Set<ArtworkReference>()
            return (explicit + legacy).filter { seen.insert($0).inserted }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if PosterCardPresentation.usesFolderArtwork(for: item.kind) {
            FolderPlaceholderArtwork(
                foreground: titleColor,
                background: titleColor.opacity(0.08),
                isFocused: isFocused,
                iconSize: PosterCardPresentation.folderIconSize(for: style)
            )
        } else if showsSeriesArtwork {
            seriesArtwork
        } else if showsSpoilerSafePoster {
            // Series art, unblurred — see `showsSpoilerSafePoster`. Both spoiler
            // modes land here: `.placeholder` asked for series art already, and
            // `.blur` was only ever blurring series art too.
            placeholderArtwork
        } else if hideThumbnail {
            switch spoilerSettings.mode {
            case .blur:
                realArtwork.blur(radius: 28)
            case .placeholder:
                placeholderArtwork
            }
        } else if artworkReferences.isEmpty && asyncArtworkFallback == nil {
            // No real art candidates and no last-resort resolver — e.g. an
            // un-enriched SMB card in the browse grid (async fallback disabled).
            // Render the neutral placeholder DIRECTLY instead of going through
            // FilteredArtworkImage, which would spin up a per-card `.task` and flip
            // gray→placeholder. On an SMB library with many unmatched items that
            // removes a live task from every posterless cell during scroll.
            neutralPlaceholder
        } else {
            realArtwork
        }
    }

    private var realArtwork: some View {
        FallbackAsyncImage(
            references: artworkReferences,
            maxAspectRatio: posterAspectGuard,
            variant: artworkVariant,
            asyncFallbackURL: asyncArtworkFallback
        ) {
            neutralPlaceholder
        }
    }

    private var artworkVariant: ArtworkImageVariant {
        switch style {
        case .poster: return .posterCard
        case .landscape: return .landscapeCard
        }
    }

    /// The async (TMDb) last-resort source for whichever card shape this is: a
    /// vertical poster for poster cards, a wide backdrop for landscape cards. For
    /// a landscape *episode* card it first tries the real per-episode still (a
    /// genuine thumbnail), then falls back to the show's backdrop — anime via
    /// Shoko/AniDB usually ship no per-episode image, so TMDb supplies it.
    private var asyncArtworkFallback: (@Sendable () async -> URL?)? {
        guard enablesAsyncArtworkFallback else { return nil }
        // The inner resolver (the actual network lookup) for this card's style.
        let inner: (@Sendable () async -> URL?)?
        if style == .poster {
            inner = tmdbPosterFallback
        } else if item.kind == .episode,
                  item.seasonNumber != nil,
                  item.episodeNumber != nil {
            let snapshot = item
            let seriesItem = Self.seriesArtworkItem(for: item)
            let serverSeriesBackdrop = item.fallbackArtworkURL
            inner = {
                // 1) Real per-episode still first (TMDb stills, then TVmaze for
                //    western TV). Anime via Shoko/AniDB usually ship none.
                if let still = await ArtworkRouter.shared.artworkURL(.thumbnail, for: snapshot) {
                    return still
                }
                // 2) Series-level wide hero so an episode card is never blank: a
                //    high-res TMDb backdrop when configured, otherwise the keyless
                //    AniList banner for anime. The same banner on every episode of
                //    a show is acceptable; a blank card is not.
                if let seriesHero = await ArtworkRouter.shared.artworkURL(.hero, for: seriesItem) {
                    return seriesHero
                }
                // 3) Last resort: the server's own series backdrop, if present.
                return serverSeriesBackdrop
            }
        } else {
            inner = tmdbBackdropFallback
        }
        guard let inner else { return nil }
        // Bound concurrent grid-card resolutions so a large un-enriched library
        // (SMB) can't flood the metadata network + ArtworkRouter actor while
        // scrolling. Skip the network call entirely if this card scrolled away
        // (its .task was cancelled) before a permit freed up.
        return {
            await ArtworkSession.artworkResolveLimiter.run {
                if Task.isCancelled { return nil }
                return await inner()
            }
        }
    }

    /// A lightweight *series-level* item synthesized from an episode, used only to
    /// resolve a wide series hero (TMDb backdrop or the keyless AniList banner) as
    /// a guaranteed non-blank fallback for episode cards. Carries the episode's
    /// normalized provider IDs, title, genres and tags so anime detection and
    /// cross-provider lookups stay accurate at the series level.
    ///
    /// Internal rather than private so `EpisodeColumnCard` can resolve spoiler-safe
    /// series art through the same synthesized item.
    static func seriesArtworkItem(for episode: MediaItem) -> MediaItem {
        MediaItem(
            id: episode.seriesID ?? episode.id,
            title: episode.parentTitle ?? episode.title,
            kind: .series,
            productionYear: episode.productionYear,
            genres: episode.genres,
            tags: episode.tags,
            seriesID: episode.seriesID,
            fallbackArtworkURL: episode.fallbackArtworkURL,
            providerIDs: episode.providerIDs
        )
    }

    /// Poster cards reject any source image wider than ~0.9:1 (a real poster is
    /// ~0.67:1), so 16:9 stills and wide composites fall through to the clean
    /// placeholder. Landscape/backdrop art has no guard.
    private var posterAspectGuard: CGFloat? {
        style == .poster ? 0.9 : nil
    }

    /// Last-resort poster source for poster cards whose provider art is missing
    /// or junk: look the title up on TMDb (movies by title+year; series/episodes
    /// by the *series* title). Inert when no TMDb token is configured.
    private var tmdbPosterFallback: (@Sendable () async -> URL?)? {
        guard style == .poster else { return nil }
        switch item.kind {
        case .folder, .collection, .unknown:
            return nil
        default:
            break
        }
        let snapshot = item
        return {
            await ArtworkRouter.shared.artworkURL(.poster, for: snapshot)
        }
    }

    /// Last-resort backdrop source for landscape cards whose provider thumbnail is
    /// missing (common for anime episodes via Shoko/AniDB): look the show up on
    /// TMDb and use a wide fanart image. Episodes/seasons query by the *series*
    /// title; movies/series by their own. Inert without a TMDb token.
    private var tmdbBackdropFallback: (@Sendable () async -> URL?)? {
        guard style == .landscape else { return nil }
        switch item.kind {
        case .folder, .collection, .unknown:
            return nil
        default:
            break
        }
        let snapshot = item
        return {
            await ArtworkRouter.shared.artworkURL(.hero, for: snapshot)
        }
    }

    /// Spoiler-safe art for `.placeholder` mode: only ever **series-level** art,
    /// never the real episode frame.
    ///
    /// This deliberately mirrors `realArtwork`'s shape — server art first, then an
    /// `ArtworkRouter` last resort — because for a long time it did not. It read a
    /// single URL and fell straight through to a grey box, which made
    /// `.placeholder` strictly worse than `.blur` for art coverage. Worse,
    /// `fallbackArtworkURL` was only ever populated by Jellyfin, so on Plex and
    /// direct shares that grey box was *every* hidden episode.
    ///
    /// Nothing here may reach for `posterURL`/`backdropURL`: on Jellyfin those are
    /// the episode's own primary and backdrop images — exactly what this mode
    /// exists to hide. Only fields documented as parent/series-scoped qualify.
    private var placeholderArtwork: some View {
        FallbackAsyncImage(
            references: placeholderArtworkReferences,
            maxAspectRatio: posterAspectGuard,
            variant: artworkVariant,
            asyncFallbackURL: placeholderArtworkFallback
        ) {
            neutralPlaceholder
        }
    }

    /// Server-supplied series art, ordered for this card's shape: a poster card
    /// wants the show's vertical poster, a landscape card its wide backdrop. Each
    /// keeps the other as a last resort — a cropped poster still identifies the
    /// show, and a blank card does not.
    private var placeholderArtworkReferences: [ArtworkReference] {
        // Direct-share local artwork, but only the explicitly series-scoped
        // selection. Going through `artworkReferences(for: .seriesPoster)` would
        // append that placement's legacy ladder, which ends in the episode's own
        // `posterURL`.
        let localSeriesArt = item.artworkSelections
            .first(where: { $0.placement == .seriesPoster })?
            .references ?? []
        let remote: [URL?] = style == .poster
            ? [item.seriesPosterURL, item.fallbackArtworkURL]
            : [item.fallbackArtworkURL, item.seriesPosterURL]
        let ordered = style == .poster
            ? localSeriesArt + remote.compactMap { $0.map(ArtworkReference.remote) }
            : remote.compactMap { $0.map(ArtworkReference.remote) } + localSeriesArt
        var seen = Set<ArtworkReference>()
        return ordered.filter { seen.insert($0).inserted }
    }

    /// Last-resort series art from the metadata router, so a show whose server
    /// carries no art at all still gets a recognisable card. Asks only for
    /// **series-scoped** kinds against a synthesized series item — never
    /// `.thumbnail`, which resolves the episode's own still.
    private var placeholderArtworkFallback: (@Sendable () async -> URL?)? {
        guard enablesAsyncArtworkFallback else { return nil }
        let seriesItem = Self.seriesArtworkItem(for: item)
        let kind: ArtworkKind = style == .poster ? .poster : .hero
        return {
            await ArtworkSession.artworkResolveLimiter.run {
                if Task.isCancelled { return nil }
                return await ArtworkRouter.shared.artworkURL(kind, for: seriesItem)
            }
        }
    }

    /// Neutral stand-in when a card has no artwork. Uses the shared
    /// `MediaArtworkPlaceholder` so every surface looks identical, tinted with
    /// the caption colour so it flips on focus and respects reduced-transparency.
    private var neutralPlaceholder: some View {
        MediaArtworkPlaceholder(tint: subtitleColor)
    }

    // MARK: Series-identified artwork (Continue Watching)

    /// The show's own wide art with its logo laid over it.
    ///
    /// Continue Watching is one entry per show, so what the card has to answer
    /// first is "which show is this" — and a row of episode stills from shows the
    /// viewer is part-way through answers that poorly, because mid-episode frames
    /// from different shows look alike. The show's art plus its logo is the same
    /// thing a shelf of DVD spines does.
    /// The show's own wide art with its logo laid over it.
    ///
    /// Nothing is drawn until we know **which** picture this card should use.
    /// Textless art is this feature's primary source and the server's art is its
    /// fallback, so painting the server's first and correcting later has the
    /// relationship backwards: it puts a picture on screen that the card may be
    /// about to replace, and a replacement the viewer can see is a defect however
    /// smoothly it is done.
    ///
    /// This costs nothing on the path that matters. Answers are read back from
    /// disk synchronously, so on every launch after a show's first appearance
    /// ``TextlessBackdropStore/hasAnswer(for:)`` is already true on the first
    /// frame and the picture goes straight up. Only a show being seen for the
    /// very first time waits, and it waits showing the same neutral placeholder
    /// every card already shows while its art loads — not the wrong picture.
    private var seriesArtwork: some View {
        Group {
            if textlessAnswerReady {
                seriesArtworkPicture
            } else {
                neutralPlaceholder
            }
        }
        // Settles this show's source, then lets the body re-read it. A plain
        // synchronous read gives SwiftUI nothing to invalidate on, so without this
        // the answer would land in a dictionary no view was watching.
        .task(id: item.id) {
            guard !TextlessBackdropStore.shared.hasAnswer(for: item) else { return }
            // Ask on the card's own behalf. The row warms its forward window, but
            // a card must not depend on having been prefetched — the first card of
            // a freshly loaded row appears at the same moment the row asks, and a
            // card used outside a row is never asked for at all.
            TextlessBackdropStore.shared.warm(for: item, variant: artworkVariant)
            await Self.settleTextlessAnswer(for: item)
            textlessAnswerRevision &+= 1
        }
        // The show's name moved onto the artwork (as a logo, which carries no text
        // for VoiceOver), and out of the caption — which now reads "S2 · E5". Name
        // the artwork so the card still announces WHAT it is, not just where in it
        // you are.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(seriesDisplayTitle)
    }

    /// Waits for this show's artwork source to be decided, but never indefinitely.
    ///
    /// A lookup that cannot finish — no network, a provider that is down, TMDb
    /// switched off entirely — must not leave the card blank. Past the deadline
    /// the server's art is used, which is exactly its job: the fallback for when
    /// nothing better can be had.
    private static func settleTextlessAnswer(for item: MediaItem) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await TextlessBackdropStore.shared.answerSettled(for: item) }
            group.addTask {
                try? await Task.sleep(nanoseconds: textlessAnswerDeadlineNanoseconds)
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Long enough for a cache hit or a prompt lookup, short enough that a card
    /// which will never get an answer is not visibly stalled.
    private static let textlessAnswerDeadlineNanoseconds: UInt64 = 3_000_000_000

    /// Whether this card knows which picture to draw. `textlessAnswerRevision` is
    /// read first so the body re-evaluates when the answer lands; it is also what
    /// records that the deadline passed.
    private var textlessAnswerReady: Bool {
        textlessAnswerRevision > 0 || TextlessBackdropStore.shared.hasAnswer(for: item)
    }

    private var seriesArtworkPicture: some View {
        FallbackAsyncImage(
            references: seriesArtworkReferences,
            maxAspectRatio: posterAspectGuard,
            variant: artworkVariant,
            asyncFallbackURL: seriesArtworkFallback,
            onResolveReference: { reference in
                // A `nil` reference means the metadata router supplied the art
                // late, from outside the ordered list. That path asks TMDb first
                // and TMDb is ranked textless-backdrop-first, so it is the least
                // likely candidate of all to carry a title — treat it as clean.
                artworkAlreadyCarriesTitle = reference.map(titleBearingArtwork.contains) ?? false
            },
            pinIdentity: item.id,
            // The card is taller than the picture, so the picture is laid in at
            // its own shape and the band left underneath is filled with a
            // mirrored continuation of it — never by cropping the sides down to
            // the card's shape, which on a backdrop means cutting a fifth of the
            // frame off, and never by the blurred blow-up that costs the picture
            // its whole lower half.
            content: { ExtendedArtworkFill(image: $0) }
        ) {
            neutralPlaceholder
        }
        // A logo drawn over art that already shows the title says it twice — see
        // ``titleBearingArtwork`` and ``TextlessBackdropStore/suppressesLogo(for:)``.
        .overlay { if !suppressesSeriesLogo { seriesLogo } }
    }

    private var titleBearingArtwork: Set<ArtworkReference> {
        PosterCardPresentation.titleBearingArtwork(for: item)
    }

    /// Whether to leave the logo off entirely, for either reason: the winning
    /// candidate is a slot that names itself, or no textless art exists anywhere
    /// for a show whose only art is titled promotional key art.
    private var suppressesSeriesLogo: Bool {
        artworkAlreadyCarriesTitle || TextlessBackdropStore.shared.suppressesLogo(for: item)
    }

    /// For an episode this is the spoiler-safe series ladder (never the episode's
    /// own frame). A movie or series already *is* the show, so it keeps its own
    /// art.
    ///
    /// A known-textless backdrop leads, because this card draws the show's logo
    /// over its picture and the server's own art frequently has the title baked
    /// in — which prints the name twice. See ``TextlessBackdropStore`` for why the
    /// answer is fetched rather than inferred, and why reading it here (during
    /// body, synchronously) is what keeps the switch invisible.
    private var seriesArtworkReferences: [ArtworkReference] {
        let ladder = item.kind == .episode ? placeholderArtworkReferences : artworkReferences
        guard showsSeriesArtwork else { return ladder }
        return PosterCardPresentation.preferringTextless(
            TextlessBackdropStore.shared.backdrop(for: item),
            over: ladder
        )
    }

    private var seriesArtworkFallback: (@Sendable () async -> URL?)? {
        item.kind == .episode ? placeholderArtworkFallback : asyncArtworkFallback
    }

    /// The show's logo, centred so it clears the resume chip along the bottom and
    /// the watch-state badge in the top corners.
    ///
    /// `HeroLogoArtwork` always renders *something* — it shows the styled title
    /// while the logo resolves and keeps it when none is ever found — so the card
    /// carries the show's identity whether or not a logo exists. That matters
    /// here: logos come from the provider or from TMDb/Wikidata, and TMDb is off
    /// unless the user supplies a token, so a good share of libraries will have
    /// none. The text path is the design, not an error state.
    private var seriesLogo: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            // The picture's own band. Sizing the logo against it — rather than
            // against the card — keeps the chrome band underneath as its own
            // space, so growing the logo can never crowd the progress bar and
            // "S1, E12 · 17m".
            let stage = height * ContinueWatchingCardShape.mirrorLine
            let box = ContinueWatchingCardShape.logoBox(cardWidth: width, stage: stage, edgeInset: metrics.resumeChipInset)
            ZStack(alignment: .top) {
                // An even dim over the whole card, deepened when the resolved
                // logo turns out to be the kind that vanishes into artwork — see
                // ``ContinueWatchingCardShape/artworkDim(forLogoLuminance:)``.
                // Animated because the logo arrives asynchronously, and a backdrop
                // that steps darker the moment it lands would read as a flicker.
                Color.black.opacity(
                    ContinueWatchingCardShape.artworkDim(logo: logoTone, background: artworkTone)
                )
                .animation(.easeOut(duration: 0.25), value: logoTone)
                .animation(.easeOut(duration: 0.25), value: artworkTone)
                HeroLogoArtwork(
                    references: item.artworkReferences(for: .logo),
                    asyncFallbackURL: seriesLogoFallback,
                    maxWidth: box.width,
                    maxHeight: box.height,
                    alignment: .center,
                    // No background sample is taken per card (that would be an
                    // image analysis per card while scrolling), so the halo is
                    // always drawn — and an adaptive one put a white glow behind
                    // every mid-to-dark logo. Down, always: it reads as depth
                    // rather than as an effect, and the scrim above already
                    // darkens the artwork under the logo.
                    haloStyle: .gentle,
                    // Lets a logo that is losing against its own picture lift
                    // itself, which is what dimming the backdrop cannot do once
                    // the backdrop is already dark — see ``LogoToneLift``.
                    logoNeedsHelp: seriesLogoNeedsHelp,
                    onResolve: { logoTone = $0 }
                ) {
                    seriesLogoTextFallback(width: width)
                }
                .frame(width: width, height: box.height)
                // Sits between the picture's centre and the card's — see
                // ``ContinueWatchingCardShape/logoCenter``.
                .offset(y: height * ContinueWatchingCardShape.logoCenter - box.height / 2)
            }
            .frame(width: width, height: height)
        }
        .allowsHitTesting(false)
        .task(id: seriesArtworkSampleKey) {
            // Samples the SAME decoded image the card is displaying (the
            // `.landscapeCard` variant), so this reads pixels that are already
            // resident rather than commissioning a bigger decode. Results are
            // memoized by reference + region and concurrent requests coalesced
            // (see ``HeroBackgroundSampler``), so a rail that scrolls back and
            // forth pays for each card once.
            artworkTone = await HeroBackgroundSampler.sample(
                references: seriesArtworkReferences,
                region: ContinueWatchingCardShape.logoSampleRegion,
                variant: artworkVariant
            )
        }
    }

    /// How badly this card's logo is losing against its own artwork, once both
    /// have been measured. Shared with the backdrop dim so the two remedies always
    /// agree about whether there is a problem.
    private var seriesLogoNeedsHelp: Double? {
        guard let logoTone, let artworkTone else { return nil }
        return 1 - ContinueWatchingCardShape.separation(logo: logoTone, background: artworkTone)
    }

    /// Re-samples only when the artwork this card shows actually changes.
    private var seriesArtworkSampleKey: String {
        seriesArtworkReferences.map(\.privacySafeIdentity).joined(separator: "|")
    }

    /// The readable stand-in shown while the logo resolves, and kept when there
    /// isn't one. Sized off the card so it holds up at any display density.
    ///
    /// The factor stands in for a *logo*, not for body text, so it tracks the
    /// logo's own budget rather than the card: it was raised when the card shrank
    /// so a show without artwork reads at the size it always did, exactly as a
    /// show with artwork does.
    private func seriesLogoTextFallback(width: CGFloat) -> some View {
        seriesDisplayTitle
            .font(.system(size: max(17, width * 0.092), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.65), radius: 6, y: 2)
            .padding(.horizontal, width * 0.08)
    }

    /// The show's name: an episode's owning series, otherwise the item's own.
    ///
    /// `Text` rather than `String`: the masked case is our own copy, and the other
    /// two are media titles rendered verbatim. The choice itself is
    /// ``PosterCardPresentation/seriesArtworkTitleSource(kind:hasSeriesTitle:hidesText:)``
    /// so the spoiler rule is unit-tested without rendering.
    private var seriesDisplayTitle: Text {
        switch PosterCardPresentation.seriesArtworkTitleSource(
            kind: item.kind,
            hasSeriesTitle: !(item.parentTitle ?? "").isEmpty,
            hidesText: hideText
        ) {
        case .seriesTitle:
            return Text(verbatim: item.parentTitle ?? item.title)
        case .maskedEpisode:
            return Text(spoilerSettings.maskedTitle(for: item))
        case .ownTitle:
            return Text(verbatim: item.title)
        }
    }

    /// Router-resolved logo, for the many libraries whose server carries none.
    /// Bounded by the shared resolve limiter so a scrolling row can't fire one
    /// lookup per card at once.
    private var seriesLogoFallback: (@Sendable () async -> URL?)? {
        guard enablesAsyncArtworkFallback else { return nil }
        let target = item.kind == .episode ? Self.seriesArtworkItem(for: item) : item
        return {
            await ArtworkSession.artworkResolveLimiter.run {
                if Task.isCancelled { return nil }
                return await ArtworkRouter.shared.artworkURL(.logo, for: target)
            }
        }
    }

    // MARK: Progress

    @ViewBuilder
    private func statusCue(inset: CGFloat) -> some View {
        if let statusCueText {
            Text(statusCueText)
                .font(.system(size: metrics.cardStatusCueFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, metrics.cardStatusCueHorizontalPadding)
                .padding(.vertical, metrics.cardStatusCueVerticalPadding)
                .background(.black.opacity(0.72), in: Capsule(style: .continuous))
                .padding(inset)
                .accessibilityLabel(Text(statusCueText))
        }
    }

}

/// Pure presentation policy so folder treatment stays testable without rendering
/// SwiftUI. Folders retain the shared poster footprint/focus mechanics but never
/// look like playable, unwatched media.
enum PosterCardPresentation {
    /// The candidates that are **key art** rather than a clean backdrop, and so
    /// almost certainly have the show's name set into them already.
    ///
    /// A poster is designed to be seen alone, which means it is designed to name
    /// itself. Laying our own wordmark over one prints the title twice.
    ///
    /// Deliberately decided by *provenance* rather than by looking at the picture,
    /// and only for the poster slots — the one place where "this art names itself"
    /// is a property of the slot rather than a guess about the show.
    ///
    /// Widening it to "every backdrop belonging to an anime" was tried and
    /// reverted. Whether a given backdrop has the title burned into it is a fact
    /// about the *pixels*, and no metadata field stands in for it: the genre/id
    /// test it was keyed on ("Anime") was wrong in both directions at once —
    /// Arcane matched and lost a logo it should have kept, while "Let's go
    /// KAIKIGUMI" and "Black Cat and a Witch", the two shows the rule existed to
    /// fix, did not match and went on doubling. A test that mislabels both the
    /// cases it was aimed at and the cases it wasn't is not a signal, so the card
    /// keeps its logo unless the art came from a slot that is titled by
    /// definition.
    static func titleBearingArtwork(for item: MediaItem) -> Set<ArtworkReference> {
        var titled: Set<ArtworkReference> = []
        if let poster = item.seriesPosterURL { titled.insert(.remote(poster)) }
        // A movie or series shows its own art, where `posterURL` is the poster.
        if item.kind != .episode, let poster = item.posterURL { titled.insert(.remote(poster)) }
        item.artworkSelections
            .filter { $0.placement == .seriesPoster || $0.placement == .poster }
            .flatMap(\.references)
            .forEach { titled.insert($0) }
        return titled
    }

    /// Puts a known-textless backdrop at the head of the candidate ladder.
    ///
    /// The server's art stays in the list rather than being replaced: "textless"
    /// is a claim about the URL we resolved, not a promise that it will load, and
    /// a card that fails to a blank is worse than one that shows a doubled title.
    /// It is de-duplicated because the server's backdrop and the resolved one are
    /// occasionally the same picture, and a list that names it twice would make
    /// the retry loop try it twice before moving on.
    static func preferringTextless(
        _ textless: URL?,
        over ladder: [ArtworkReference]
    ) -> [ArtworkReference] {
        guard let textless else { return ladder }
        let clean = ArtworkReference.remote(textless)
        return [clean] + ladder.filter { $0 != clean }
    }


    enum SeriesArtworkTitleSource: Equatable {
        /// The owning series' name (`parentTitle`).
        case seriesTitle
        /// The item's own title — correct for a movie or series, which *is* the
        /// show.
        case ownTitle
        /// A spoiler-safe stand-in ("Episode 5").
        case maskedEpisode
    }

    /// Picks the title a series-artwork card may draw.
    ///
    /// The episode branch is the load-bearing one. An episode that arrives with no
    /// `parentTitle` has no show name to fall back to, and its own `title` is the
    /// *episode's* title — precisely what spoiler protection exists to keep off
    /// the screen. Drawing it here, in the largest type on the card, would be a
    /// worse leak than the thumbnail this mode replaced, so it masks instead.
    static func seriesArtworkTitleSource(
        kind: MediaItemKind,
        hasSeriesTitle: Bool,
        hidesText: Bool
    ) -> SeriesArtworkTitleSource {
        guard kind == .episode else { return .ownTitle }
        if hasSeriesTitle { return .seriesTitle }
        return hidesText ? .maskedEpisode : .ownTitle
    }

    static func usesFolderArtwork(for kind: MediaItemKind) -> Bool {
        kind == .folder
    }

    static func showsWatchStatus(for kind: MediaItemKind) -> Bool {
        kind != .folder
    }

    static func showsPlaybackIndicators(for kind: MediaItemKind) -> Bool {
        kind != .folder
    }

    static func folderIconSize(for style: PosterCardView.Style) -> CGFloat {
        switch style {
        case .poster: return 48
        case .landscape: return 52
        }
    }

    static func folderIconOpacity(isFocused: Bool) -> Double {
        isFocused ? 0.52 : 0.4
    }
}

/// Dedicated folder artwork: a generic symbol only. The item's real title stays
/// in the normal caption below the card, so it is never duplicated in the poster.
private struct FolderPlaceholderArtwork: View {
    let foreground: Color
    let background: Color
    let isFocused: Bool
    let iconSize: CGFloat

    var body: some View {
        ZStack {
            background
            Image(systemName: "folder.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(
                    foreground.opacity(
                        PosterCardPresentation.folderIconOpacity(isFocused: isFocused)
                    )
                )
        }
    }
}

public extension View {
    /// Makes a card a focusable, tappable surface **without** wrapping it in a
    /// `Button`. On tvOS a `Button` (even `.buttonStyle(.plain)`) paints the
    /// system focus *platter* — a stark white plate behind the focused card that
    /// `.focusEffectDisabled()` can't fully remove and that buries our own glass
    /// focus treatment (most visible on dark and Pure Black themes). Following Twozz's
    /// card pattern, we instead drive focus with `.focusable` + `.onTapGesture`
    /// (the select-press fires the tap) and disable the system focus effect, so
    /// the only focus visuals are the ones we draw via `plozzGlassCard`.
    func focusableCard(
        isFocused: FocusState<Bool>.Binding,
        cornerRadius: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        #if os(tvOS)
        contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .focusable(true)
            .focused(isFocused)
            .focusEffectDisabled()
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
        #else
        contentShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        #endif
    }
}

public extension MediaItem {
    /// Ordered real-image candidates a `PosterCardView` of `style` will try before
    /// any async (TMDb) fallback. Rails use this to prefetch each card's artwork
    /// into `ArtworkImageCache` ahead of scroll, so a card already has its decoded
    /// thumbnail the moment it appears. Mirrors `PosterCardView.artworkCandidates`.
    func artworkCandidates(for style: PosterCardView.Style) -> [URL] {
        switch style {
        case .poster:
            // A poster grid always wants the vertical show/movie poster. For an
            // episode that means the *series* poster, never the episode's own
            // 16:9 still (which would render as a wide card).
            if kind == .episode {
                return [seriesPosterURL, posterURL, fallbackArtworkURL].compactMap { $0 }
            }
            return [posterURL, fallbackArtworkURL].compactMap { $0 }
        case .landscape:
            if kind == .episode {
                // An episode's thumbnail is its own Primary (then Backdrop) image.
                // The series backdrop is deliberately *not* a direct fallback (it
                // would paint the same image on every episode); the async TMDb
                // fallback supplies a real per-episode still instead.
                return [posterURL, backdropURL].compactMap { $0 }
            }
            return [backdropURL, posterURL, fallbackArtworkURL].compactMap { $0 }
        }
    }
}

#endif
