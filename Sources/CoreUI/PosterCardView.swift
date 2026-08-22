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
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzMetrics) private var metrics
    /// Per-profile card presentation (framed glass card vs borderless artwork).
    @Environment(\.plozzCardStyle) private var cardStyle

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
    private var hideText: Bool { spoilerSettings.shouldHideText(for: item) }

    /// Title/subtitle colour, flipped to dark ink over a focused card's opaque
    /// "lift" surface. Centralised in `PlozzCardCaption` so every card type flips
    /// identically.
    private var titleColor: Color {
        PlozzCardCaption.titleColor(isFocused: isFocused, reduceTransparency: reduceTransparency)
    }
    private var subtitleColor: Color {
        PlozzCardCaption.subtitleColor(isFocused: isFocused, reduceTransparency: reduceTransparency)
    }

    private var size: CGSize {
        switch style {
        case .poster:
            return CGSize(width: metrics.posterWidth, height: metrics.posterHeight)
        case .landscape:
            return CGSize(width: metrics.landscapeWidth, height: metrics.landscapeHeight)
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
            isFocused: isFocused
        )
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.posterCardCornerRadius, action: action)
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
        // Resting posters carry a soft drop shadow so they read as raised cards
        // (essential in Light mode against a white background); the focused card
        // deepens it. Resting cards now wear the cheap frosted `.ultraThinMaterial`
        // (no live-glass per-frame cost), so the surface returns without the scroll
        // lag that a live resting `.glassEffect` caused.
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0.15), radius: isFocused ? 20 : 8, y: isFocused ? 10 : 4)
        .scaleEffect(isFocused ? PlozzTheme.Metrics.focusedCardScale : 1)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
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
        .plozzFramedMediaCard(
            innerCornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
            isFocused: isFocused
        )
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.landscapeCardCornerRadius, action: action)
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0.15), radius: isFocused ? 20 : 8, y: isFocused ? 10 : 4)
        .scaleEffect(isFocused ? PlozzTheme.Metrics.mediumFocusedCardScale : 1)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
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
        .padding(.horizontal, metrics.borderlessCardSideMargin)
        .focusableCard(isFocused: $isFocused, cornerRadius: borderlessCornerRadius, action: action)
        // A borderless card's focus halo + scale bloom extend *beyond* the layout
        // bounds. `compositingGroup` composites them as one unit without clipping;
        // `drawingGroup` (what `plozzCardRasterize` uses under Reduce Transparency)
        // would rasterize to the layout bounds and shear off the halo + bloom.
        .compositingGroup()
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
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
        case .landscape: return 16.0 / 9.0
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
                || showsActionsMenu)
    }

    /// The shared resume affordance — identical to the episode card's overlay.
    @ViewBuilder
    private var resumeChip: some View {
        if showsResumeChip {
            ResumeChipOverlay(
                item: item,
                downloadState: downloadState,
                showsMenu: showsActionsMenu
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
    private var seriesArtwork: some View {
        FallbackAsyncImage(
            references: seriesArtworkReferences,
            maxAspectRatio: posterAspectGuard,
            variant: artworkVariant,
            asyncFallbackURL: seriesArtworkFallback
        ) {
            neutralPlaceholder
        }
        .overlay { seriesLogo }
        // The show's name moved onto the artwork (as a logo, which carries no text
        // for VoiceOver), and out of the caption — which now reads "S2 · E5". Name
        // the artwork so the card still announces WHAT it is, not just where in it
        // you are.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(seriesDisplayTitle)
    }

    /// For an episode this is the spoiler-safe series ladder (never the episode's
    /// own frame). A movie or series already *is* the show, so it keeps its own
    /// art.
    private var seriesArtworkReferences: [ArtworkReference] {
        item.kind == .episode ? placeholderArtworkReferences : artworkReferences
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
            ZStack {
                // Keeps a pale or busy backdrop from swallowing the logo. Kept
                // light: the bottom chrome already lays down its own scrim, and
                // stacking two reads as a muddy card.
                Color.black.opacity(0.22)
                HeroLogoArtwork(
                    references: item.artworkReferences(for: .logo),
                    asyncFallbackURL: seriesLogoFallback,
                    maxWidth: width * 0.66,
                    maxHeight: height * 0.34,
                    alignment: .center
                ) {
                    seriesLogoTextFallback(width: width)
                }
            }
            .frame(width: width, height: height)
        }
        .allowsHitTesting(false)
    }

    /// The readable stand-in shown while the logo resolves, and kept when there
    /// isn't one. Sized off the card so it holds up at any display density.
    private func seriesLogoTextFallback(width: CGFloat) -> some View {
        seriesDisplayTitle
            .font(.system(size: max(17, width * 0.082), weight: .bold, design: .rounded))
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
    /// Which title a series-artwork card draws over its artwork.
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
