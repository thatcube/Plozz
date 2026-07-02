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
    private let enablesAsyncArtworkFallback: Bool
    private let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzMetrics) private var metrics
    /// Per-profile card presentation (framed glass card vs borderless artwork).
    @Environment(\.plozzCardStyle) private var cardStyle

    public init(
        item: MediaItem,
        style: Style = .poster,
        spoilerSettings: SpoilerSettings = .default,
        enablesAsyncArtworkFallback: Bool = true,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.style = style
        self.spoilerSettings = spoilerSettings
        self.enablesAsyncArtworkFallback = enablesAsyncArtworkFallback
        self.action = action
    }

    private var hideThumbnail: Bool { spoilerSettings.shouldHideThumbnail(for: item) }
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
                .overlay(alignment: .topTrailing) { watchedBadge(inset: 8) }
                .overlay(alignment: .bottom) { progressBar(height: 12, hInset: 16, bottomInset: 16) }
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Text(subtitleText ?? " ")
                    .font(.system(size: metrics.cardSubtitleFontSize))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .opacity(subtitleText == nil ? 0 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .bottom], metrics.posterCaptionInset)
        }
        .padding(metrics.cardInset)
        .plozzGlassCard(cornerRadius: metrics.posterCardCornerRadius, isFocused: isFocused)
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.posterCardCornerRadius, action: action)
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
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
                .overlay(alignment: .topTrailing) { watchedBadge(inset: 8) }
                .overlay(alignment: .bottom) { progressBar(height: 12, hInset: 16, bottomInset: 16) }
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius)

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryText)
                    .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Text(subtitleText ?? " ")
                    .font(.system(size: metrics.cardSubtitleFontSize))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .opacity(subtitleText == nil ? 0 : 1)
            }
            .padding([.horizontal, .bottom], metrics.landscapeCaptionInset)
            .frame(width: size.width, alignment: .leading)
        }
        .padding(metrics.cardInset)
        .plozzGlassCard(cornerRadius: metrics.landscapeCardCornerRadius, isFocused: isFocused)
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
                horizontalInset: borderlessCaptionInset
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
            .overlay(alignment: .topTrailing) { watchedBadge(inset: borderlessBadgeInset) }
            .overlay(alignment: .bottom) {
                progressBar(
                    height: metrics.progressBarHeight,
                    hInset: borderlessProgressInset,
                    bottomInset: borderlessProgressInset
                )
            }
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
    /// rounded corner. The badge is a 30pt circle (radius 15), so its inset is
    /// `outerRadius − 15`, matching the progress bar's even spacing.
    private var borderlessBadgeInset: CGFloat {
        max(borderlessCornerRadius - 15, 8)
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
    private var primaryText: String {
        if item.kind == .episode, let series = item.parentTitle, !series.isEmpty {
            return series
        }
        if hideText { return spoilerSettings.maskedTitle(for: item) }
        return item.title
    }

    /// Secondary line — subtitle facts plus card runtime/remaining when available.
    private var subtitleText: String? {
        var parts: [String] = []
        if let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if let runtime = item.cardRuntimeText?.trimmingCharacters(in: .whitespacesAndNewlines), !runtime.isEmpty {
            parts.append(runtime)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    // MARK: Artwork

    /// Ordered list of real-image candidates to try before showing a placeholder.
    private var artworkCandidates: [URL] {
        item.artworkCandidates(for: style)
    }

    @ViewBuilder
    private var artwork: some View {
        if hideThumbnail {
            switch spoilerSettings.mode {
            case .blur:
                realArtwork.blur(radius: 28)
            case .placeholder:
                placeholderArtwork
            }
        } else {
            realArtwork
        }
    }

    private var realArtwork: some View {
        FallbackAsyncImage(
            urls: artworkCandidates,
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
        if style == .poster { return tmdbPosterFallback }
        if item.kind == .episode,
           item.seasonNumber != nil,
           item.episodeNumber != nil {
            let snapshot = item
            let seriesItem = Self.seriesArtworkItem(for: item)
            let serverSeriesBackdrop = item.fallbackArtworkURL
            return {
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
        }
        return tmdbBackdropFallback
    }

    /// A lightweight *series-level* item synthesized from an episode, used only to
    /// resolve a wide series hero (TMDb backdrop or the keyless AniList banner) as
    /// a guaranteed non-blank fallback for episode cards. Carries the episode's
    /// normalized provider IDs, title, genres and tags so anime detection and
    /// cross-provider lookups stay accurate at the series level.
    private static func seriesArtworkItem(for episode: MediaItem) -> MediaItem {
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

    /// Spoiler-safe art for `.placeholder` mode: only ever the series fallback
    /// artwork (never the real episode frame), then a neutral placeholder.
    private var placeholderArtwork: some View {
        FallbackAsyncImage(
            urls: [item.fallbackArtworkURL].compactMap { $0 },
            variant: artworkVariant
        ) {
            neutralPlaceholder
        }
    }

    /// Neutral, theme-agnostic placeholder showing the (series) title. Carries no
    /// episode-number text — the `S· · E·` subtitle already conveys that.
    /// Uses the shared caption colors so icon/text flip on focus and respect
    /// reduced-transparency.
    private var neutralPlaceholder: some View {
        ZStack {
            titleColor.opacity(0.08)
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(subtitleColor)
                Text(primaryText)
                    .font(.headline)
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Progress

    /// A "watched" check shown in the artwork's top corner once an item is fully
    /// played. Hidden under spoiler thumbnail-masking so it never reveals that an
    /// unseen episode exists. Mirrors the watched state the context menu toggles.
    @ViewBuilder
    private func watchedBadge(inset: CGFloat) -> some View {
        if item.isPlayed && !hideThumbnail {
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(ThemePalette.brandBlue))
                .overlay {
                    Circle()
                        .inset(by: -0.5)
                        .stroke(watchedBadgeRim, lineWidth: 1.5)
                }
                .padding(inset)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        }
    }

    /// Glass rim for the watched badge. Unlike the card's `mediaEdgeColor` (which
    /// blends with the surrounding card surface), the badge floats on artwork, so
    /// it wants a translucent glass edge that reads against the poster: a bright
    /// white highlight on dark / OLED, a soft dark edge on Light.
    private var watchedBadgeRim: Color {
        palette.isLight ? .black.opacity(0.15) : .white.opacity(0.4)
    }

    @ViewBuilder
    private func progressBar(height: CGFloat, hInset: CGFloat, bottomInset: CGFloat) -> some View {
        if let percentage = item.playedPercentage, percentage > 0.01, percentage < 0.99 {
            ZStack(alignment: .bottom) {
                // Scrim: a slight black gradient that fades up from the bottom edge,
                // reaching above the bar so the indicator pops off bright artwork.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height + 90)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track: matches the main player's scrubber — Liquid Glass on
                        // tvOS 26+, with a translucent-white fallback on older systems
                        // *and* whenever Reduce Transparency is on (OS or in-app), so
                        // the scrubber turns solid alongside every other glass surface.
                        if #available(tvOS 26.0, *), !reduceTransparency {
                            Capsule(style: .continuous)
                                .fill(.clear)
                                .glassEffect(.regular, in: Capsule(style: .continuous))
                        } else {
                            Capsule(style: .continuous)
                                .fill(.white.opacity(0.22))
                        }

                        // Fill: Plozz's brand blue rendered as Liquid Glass on
                        // tvOS 26+ (a tinted glass capsule), with a solid brand-blue
                        // fallback on older systems and under Reduce Transparency.
                        Group {
                            if #available(tvOS 26.0, *), !reduceTransparency {
                                Capsule(style: .continuous)
                                    .fill(.clear)
                                    .glassEffect(.regular.tint(ThemePalette.brandBlue), in: Capsule(style: .continuous))
                            } else {
                                Capsule(style: .continuous)
                                    .fill(ThemePalette.brandBlue)
                            }
                        }
                        .frame(width: max(height, geo.size.width * percentage))
                        .shadow(color: .black.opacity(0.35), radius: 3)
                    }
                }
                .frame(height: height)
                .padding(.horizontal, hInset)
                .padding(.bottom, bottomInset)
            }
        }
    }
}

public extension View {
    /// Makes a card a focusable, tappable surface **without** wrapping it in a
    /// `Button`. On tvOS a `Button` (even `.buttonStyle(.plain)`) paints the
    /// system focus *platter* — a stark white plate behind the focused card that
    /// `.focusEffectDisabled()` can't fully remove and that buries our own glass
    /// focus treatment (most visible on dark / OLED themes). Following Twozz's
    /// card pattern, we instead drive focus with `.focusable` + `.onTapGesture`
    /// (the select-press fires the tap) and disable the system focus effect, so
    /// the only focus visuals are the ones we draw via `plozzGlassCard`.
    func focusableCard(
        isFocused: FocusState<Bool>.Binding,
        cornerRadius: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .focusable(true)
            .focused(isFocused)
            .focusEffectDisabled()
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
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
