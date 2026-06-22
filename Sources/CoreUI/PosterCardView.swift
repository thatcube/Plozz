#if canImport(SwiftUI)
import SwiftUI
import CoreModels

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
    private let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.themePalette) private var palette

    public init(
        item: MediaItem,
        style: Style = .poster,
        spoilerSettings: SpoilerSettings = .default,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.style = style
        self.spoilerSettings = spoilerSettings
        self.action = action
    }

    private var hideThumbnail: Bool { spoilerSettings.shouldHideThumbnail(for: item) }
    private var hideText: Bool { spoilerSettings.shouldHideText(for: item) }

    /// When a focused card renders an opaque white "lift" surface (Reduce
    /// Transparency on, or pre-Liquid-Glass tvOS) its title/subtitle must flip to
    /// dark ink so they don't vanish into the white. On the translucent-glass
    /// path (tvOS 26+) the text stays primary/secondary over the glass.
    private var usesLiftText: Bool {
        guard isFocused else { return false }
        if reduceTransparency { return true }
        if #available(tvOS 26.0, *) { return false }
        return true
    }

    private var titleColor: Color { usesLiftText ? .black.opacity(0.9) : .primary }
    private var subtitleColor: Color { usesLiftText ? .black.opacity(0.6) : .secondary }

    private var size: CGSize {
        switch style {
        case .poster:
            return CGSize(width: PlozzTheme.Metrics.posterWidth, height: PlozzTheme.Metrics.posterHeight)
        case .landscape:
            return CGSize(width: PlozzTheme.Metrics.landscapeWidth, height: PlozzTheme.Metrics.landscapeHeight)
        }
    }

    public var body: some View {
        cardBody
            .mediaItemContextMenu(for: item)
    }

    @ViewBuilder
    private var cardBody: some View {
        switch style {
        case .poster:
            posterCard
        case .landscape:
            landscapeCard
        }
    }

    // MARK: Poster

    private var posterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { artwork }
                .overlay(alignment: .topTrailing) { watchedBadge }
                .overlay(alignment: .bottom) { progressBar(height: 12) }
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Text(subtitleText ?? " ")
                    .font(.system(size: 20))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .opacity(subtitleText == nil ? 0 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .padding(10)
        .plozzGlassCard(cornerRadius: PlozzTheme.Metrics.posterCardCornerRadius, isFocused: isFocused)
        .focusableCard(isFocused: $isFocused, cornerRadius: PlozzTheme.Metrics.posterCardCornerRadius, action: action)
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0), radius: 20, y: 10)
        .scaleEffect(isFocused ? PlozzTheme.Metrics.focusedCardScale : 1)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    // MARK: Landscape (medium) card

    private var landscapeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topTrailing) { watchedBadge }
                .overlay(alignment: .bottom) { progressBar(height: 12) }
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius)

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subtitleText ?? " ")
                    .font(.system(size: 20))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .opacity(subtitleText == nil ? 0 : 1)
            }
            .frame(width: size.width, alignment: .leading)
        }
        .padding(PlozzTheme.Metrics.mediumCardInset)
        .plozzGlassCard(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, isFocused: isFocused)
        .focusableCard(isFocused: $isFocused, cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, action: action)
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0), radius: 20, y: 10)
        .scaleEffect(isFocused ? PlozzTheme.Metrics.mediumFocusedCardScale : 1)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
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
        switch style {
        case .poster:
            // A poster grid always wants the vertical show/movie poster. For an
            // episode that means the *series* poster, never the episode's own
            // 16:9 still (which would render as a wide card).
            if item.kind == .episode {
                return [item.seriesPosterURL, item.posterURL, item.fallbackArtworkURL].compactMap { $0 }
            }
            return [item.posterURL, item.fallbackArtworkURL].compactMap { $0 }
        case .landscape:
            if item.kind == .episode {
                // An episode's thumbnail is its Primary image; fall back to the
                // series backdrop, then to a neutral placeholder.
                return [item.posterURL, item.backdropURL, item.fallbackArtworkURL].compactMap { $0 }
            }
            return [item.backdropURL, item.posterURL, item.fallbackArtworkURL].compactMap { $0 }
        }
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
            asyncFallbackURL: asyncArtworkFallback
        ) {
            neutralPlaceholder
        }
    }

    /// The async (TMDb) last-resort source for whichever card shape this is: a
    /// vertical poster for poster cards, a wide backdrop for landscape cards.
    private var asyncArtworkFallback: (@Sendable () async -> URL?)? {
        style == .poster ? tmdbPosterFallback : tmdbBackdropFallback
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
        let isTV: Bool
        let queryTitle: String
        switch item.kind {
        case .movie, .video:
            isTV = false
            queryTitle = item.title
        case .series, .season:
            isTV = true
            queryTitle = item.parentTitle ?? item.title
        case .episode:
            isTV = true
            // Use the series title (never the episode name) for the show poster.
            queryTitle = item.parentTitle ?? item.title
        case .folder, .collection, .unknown:
            return nil
        }
        let year = item.productionYear
        return {
            await TMDbArtworkResolver.shared.posterURL(
                title: queryTitle,
                year: isTV ? nil : year,
                isTV: isTV
            )
        }
    }

    /// Last-resort backdrop source for landscape cards whose provider thumbnail is
    /// missing (common for anime episodes via Shoko/AniDB): look the show up on
    /// TMDb and use a wide fanart image. Episodes/seasons query by the *series*
    /// title; movies/series by their own. Inert without a TMDb token.
    private var tmdbBackdropFallback: (@Sendable () async -> URL?)? {
        guard style == .landscape else { return nil }
        let isTV: Bool
        let queryTitle: String
        let tmdbID: String?
        switch item.kind {
        case .movie, .video:
            isTV = false
            queryTitle = item.title
            tmdbID = item.providerIDs["Tmdb"]
        case .series:
            isTV = true
            queryTitle = item.title
            tmdbID = item.providerIDs["Tmdb"]
        case .season, .episode:
            isTV = true
            queryTitle = item.parentTitle ?? item.title
            // An episode/season carries its *own* TMDb id (not the show's), which
            // is useless for a series backdrop. The series page stamps the show's
            // id under "SeriesTmdb" so we can resolve the same backdrop the hero
            // uses by id (a plain title search often misses anime titles).
            tmdbID = item.providerIDs["SeriesTmdb"]
        case .folder, .collection, .unknown:
            return nil
        }
        guard !queryTitle.isEmpty || (tmdbID?.isEmpty == false) else { return nil }
        let year = isTV ? nil : item.productionYear
        return {
            await TMDbArtworkResolver.shared.backdropURL(
                title: queryTitle,
                year: year,
                isTV: isTV,
                tmdbID: tmdbID
            )
        }
    }

    /// Spoiler-safe art for `.placeholder` mode: only ever the series fallback
    /// artwork (never the real episode frame), then a neutral placeholder.
    private var placeholderArtwork: some View {
        FallbackAsyncImage(urls: [item.fallbackArtworkURL].compactMap { $0 }) {
            neutralPlaceholder
        }
    }

    /// Neutral, theme-agnostic placeholder showing the (series) title. Carries no
    /// episode-number text — the `S· · E·` subtitle already conveys that.
    private var neutralPlaceholder: some View {
        ZStack {
            Color.primary.opacity(0.08)
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(primaryText)
                    .font(.headline)
                    .foregroundStyle(.primary)
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
    private var watchedBadge: some View {
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
                .padding(8)
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
    private func progressBar(height: CGFloat) -> some View {
        if let percentage = item.playedPercentage, percentage > 0.01, percentage < 0.99 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track: a dark translucent capsule so the bar reads clearly
                    // over both bright and dark artwork, with a hairline rim.
                    Capsule(style: .continuous)
                        .fill(.black.opacity(0.55))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        }

                    // Fill: glossy "liquid glass" blue — Plozz's brand blue lit by
                    // a vertical sheen and a bright rim, with a subtle glow so it
                    // pops off the poster without blooming.
                    Capsule(style: .continuous)
                        .fill(ThemePalette.brandBlue)
                        .overlay {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.55),
                                            .white.opacity(0.06),
                                            .black.opacity(0.22)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .blendMode(.plusLighter)
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(.white.opacity(0.55), lineWidth: 0.5)
                        }
                        .frame(width: max(height, geo.size.width * percentage))
                        .shadow(color: ThemePalette.brandBlue.opacity(0.5), radius: 3)
                }
            }
            .frame(height: height)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

private extension View {
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

#endif
