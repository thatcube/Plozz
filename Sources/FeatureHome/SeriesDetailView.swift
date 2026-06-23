#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// A single, self-contained page for an entire series. The hero at the top is
/// dynamic: it reflects whatever the user is currently *focused* on (not what
/// they've clicked).
///
/// Layout, top to bottom:
///   1. Hero — series by default; becomes the focused season, then the focused
///      episode, as focus moves down the page.
///   2. Season tabs ("Book One: Water", …). Focusing a tab previews that season
///      in the hero and swaps the episode rail to it; no click required.
///   3. Episode rail for the selected season. Focusing an episode previews it in
///      the hero; clicking it plays it (the parent applies resume-vs-start-over).
struct SeriesDetailView: View {
    let series: MediaItem
    let seasons: [MediaItem]
    /// Episodes attached directly to the series (used when a backend returns a
    /// flat episode list with no season containers).
    let looseEpisodes: [MediaItem]
    let viewModel: ItemDetailViewModel
    let spoilerSettings: SpoilerSettings
    let onPlay: (MediaItem) -> Void
    /// When the page was opened by tapping a specific episode, that episode. The
    /// page then fronts it in the hero, selects its season, pre-scrolls the
    /// episode row to it, and parks focus on the hero Play button.
    let initialEpisode: MediaItem?

    /// Which season's episodes the rail is currently showing. Driven by season
    /// tab focus; seeded to the "next up" season on first appearance.
    @State private var selectedSeasonID: String?
    /// The item the hero is currently presenting. Updated as focus moves; it is
    /// never cleared, so moving focus onto a non-previewing control (e.g. the
    /// hero's own Play button) keeps the last meaningful context.
    @State private var heroItem: MediaItem
    @FocusState private var focusedSeasonID: String?
    /// True once focus is *inside* the season bar. While false, only the active
    /// season chip is focusable, so entering the bar (from Play above or the
    /// episodes below) lands directly on the active season with no visible
    /// snap from a geometrically-nearer chip. Once true, every chip is focusable
    /// so left/right moves freely between seasons; it resets when focus leaves.
    @State private var seasonBarEngaged = false
    /// Drives initial focus onto the hero Play button when the page is opened
    /// targeting a specific episode, so focus lands at the top rather than down
    /// in the episode row.
    @FocusState private var playFocused: Bool

    init(
        series: MediaItem,
        seasons: [MediaItem],
        looseEpisodes: [MediaItem],
        viewModel: ItemDetailViewModel,
        spoilerSettings: SpoilerSettings,
        onPlay: @escaping (MediaItem) -> Void,
        initialSeasonID: String? = nil,
        initialEpisode: MediaItem? = nil
    ) {
        self.series = series
        self.seasons = seasons
        self.looseEpisodes = looseEpisodes
        self.viewModel = viewModel
        self.spoilerSettings = spoilerSettings
        self.onPlay = onPlay
        self.initialEpisode = initialEpisode
        // When opened via "Go to Season", pre-select that season (and front it in
        // the hero) so the page lands on the requested season rather than the
        // default one. When opened by tapping an episode, front that episode and
        // select its season instead.
        let seasonID = initialEpisode?.seasonID ?? initialSeasonID
        let initialSeason = seasonID.flatMap { id in seasons.first { $0.id == id } }
        _selectedSeasonID = State(initialValue: initialSeason?.id)
        _heroItem = State(initialValue: initialEpisode ?? initialSeason ?? series)
    }

    /// Whether the page was opened targeting a specific episode.
    private var isTargetingEpisode: Bool { initialEpisode != nil }

    /// Scroll anchor for the hero, used to keep the page pinned to the top while
    /// initial focus lands on the bottom-anchored Play button.
    private static let topAnchorID = "series-hero-top"

    var body: some View {
        scrollContent
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
            // Let the hero bleed into the top overscan inset instead of the
            // ScrollView reserving it as a blank bar above the backdrop.
            .ignoresSafeArea(.container, edges: .top)
            .task { await prepareInitialSeason() }
            // Warm the whole season's episode stills as soon as they load, so
            // cards already have their thumbnail when scrolled to rather than
            // visibly fetching it on appear.
            .task(id: stillPrefetchKey) { await prefetchSeasonStills() }
    }

    @ViewBuilder
    private var scrollContent: some View {
        // Always land initial focus on the hero Play button (top) rather than the
        // episode row or a season chip, while the episode rail merely pre-scrolls
        // to the resume/target episode below.
        scroll.defaultFocus($playFocused, true)
    }

    private var scroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    DetailHeroView(
                        item: heroItem,
                        backdropItem: series,
                        heroHeightFraction: 0.8,
                        spoilerSettings: spoilerSettings,
                        playTitle: playTarget.map { viewModel.playButtonTitle(for: $0) },
                        onPlay: playTarget.map { target in { onPlay(target) } },
                        playProgress: playTarget?.resumeProgressFraction,
                        playRemainingText: playTarget?.resumeRemainingText,
                        onPlayTrailer: trailerButtonAction,
                        fallbackTechnicalBadges: representativeTechnicalBadges,
                        playButtonFocus: $playFocused
                    )
                    .id(Self.topAnchorID)

                    // Seasons and their episodes sit together as a tighter group,
                    // with the show-level extras kept at the wider page spacing.
                    VStack(alignment: .leading, spacing: 12) {
                        if !seasons.isEmpty {
                            seasonTabBar
                        }

                        episodeRail
                    }

                    DetailExtrasView(item: series, leadingInset: PlozzTheme.Metrics.heroLeadingPadding)
                }
                .padding(.bottom, PlozzTheme.Metrics.screenPadding)
            }
            // Keep the page pinned to the top on first load. The Play button is
            // bottom-anchored in the full-screen hero, so when initial focus
            // lands on it tvOS auto-scrolls to frame it "comfortably", nudging
            // the backdrop top off screen. Snap back to the hero top so focus
            // stays on Play without the page appearing scrolled down; moving
            // down to the seasons scrolls normally from there.
            // Snap back to the hero top whenever Play regains focus (e.g. moving
            // "up" from the seasons), animated so the page glides up smoothly
            // rather than jumping instantly.
            .onChange(of: playFocused) { _, focused in
                if focused {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.scrollTo(Self.topAnchorID, anchor: .top)
            }
        }
    }

    // MARK: Season tabs

    private var seasonTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(seasons) { season in
                    seasonChip(season)
                }
            }
            .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
            .padding(.trailing, PlozzTheme.Metrics.screenPadding)
            // Headroom for the focused chip's lift so it is never clipped.
            .padding(.vertical, 12)
        }
        // Never clip a focused chip's lift, shadow or border.
        .scrollClipDisabled()
        // Treat the whole tab bar as one focus section so pressing "up" from any
        // episode — even when the rail is scrolled far to the right and no tab
        // sits directly above — reliably enters the bar instead of being trapped.
        .focusSection()
        .onChange(of: focusedSeasonID) { _, newValue in
            guard let id = newValue else {
                // Focus left the bar (up to Play, or down to the episodes); re-arm
                // the gate so the next entry again lands only on the active season.
                seasonBarEngaged = false
                return
            }
            // We're now inside the bar — open every chip to focus so left/right
            // navigation between seasons works.
            seasonBarEngaged = true
            guard let season = seasons.first(where: { $0.id == id }) else { return }
            select(season)
            heroItem = season
        }
    }

    /// A single season tab. It reads as text-only until focused or active, then
    /// lifts into a Liquid-glass pill (matching the Twozz player controls). The
    /// style is applied unconditionally so selection never changes the tab's
    /// identity — that is what keeps left/right focus moving between tabs.
    private func seasonChip(_ season: MediaItem) -> some View {
        let isSelected = selectedSeasonID == season.id
        // The chip focus can land on while *entering* the bar: the active season,
        // falling back to the first one before a selection settles, so the bar is
        // never momentarily unfocusable during initial load.
        let activeID = selectedSeasonID ?? seasons.first?.id
        let isFocusable = seasonBarEngaged || season.id == activeID
        return Button {
            select(season)
            heroItem = season
        } label: {
            Text(season.title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(PlozzSeasonTabStyle(isSelected: isSelected))
        // No system focus ring — the pill + scale is the focus treatment.
        .focusEffectDisabled()
        .focused($focusedSeasonID, equals: season.id)
        // Remove non-active seasons from the focus system until the bar is engaged,
        // so directional entry can only ever land on the active season (no snap).
        .disabled(!isFocusable)
    }

    /// Selects `season`: marks it active and kicks off (cached) episode loading
    /// so the rail and Play target are ready as focus settles on the tab.
    private func select(_ season: MediaItem) {
        selectedSeasonID = season.id
        Task { await viewModel.loadEpisodes(for: season.id) }
    }

    // MARK: Episode rail

    private var episodeRail: some View {
        let episodes = currentEpisodes
        return MediaRowView(
            title: railTitle,
            items: episodes,
            style: .landscape,
            spoilerSettings: spoilerSettings,
            // Keep focus on the hero Play button; only pre-scroll the rail so the
            // resume/target episode sits in the correct position below, ready for
            // when focus moves down into the episodes.
            initialFocusID: nil,
            initialScrollID: isTargetingEpisode ? initialEpisode?.id : SeriesResume.nextUp(in: episodes)?.id,
            leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
            onFocusChange: { focused in
                if let focused { heroItem = focused }
            },
            onSelect: onPlay
        )
        .mediaItemActionContext(
            MediaItemActionContext(
                orderedSiblings: episodes,
                precedingContainerIDs: precedingSeasonIDs
            )
        )
    }

    /// The ids of seasons that come before the one whose rail is showing, so
    /// "mark watched up to here" can also clear every earlier season in full.
    private var precedingSeasonIDs: [String] {
        guard let id = selectedSeasonID,
              let current = seasons.first(where: { $0.id == id }),
              let currentNumber = current.seasonNumber else { return [] }
        return seasons
            .filter { ($0.seasonNumber ?? .max) < currentNumber }
            .map(\.id)
    }

    /// Identifies the currently-loaded episode set for the still prefetch task, so
    /// it fires once the selected season's episodes arrive and again when the
    /// season changes — but not on every unrelated re-render.
    private var stillPrefetchKey: String {
        "\(selectedSeasonID ?? "loose")#\(currentEpisodes.count)"
    }

    /// Prefetches every loaded episode's TMDb still for the current season so the
    /// rail's thumbnails are already cached before each card scrolls into view.
    private func prefetchSeasonStills() async {
        let requests = currentEpisodes.compactMap { episode -> TMDbArtworkResolver.EpisodeStillRequest? in
            guard episode.kind == .episode,
                  let season = episode.seasonNumber,
                  let number = episode.episodeNumber else { return nil }
            return TMDbArtworkResolver.EpisodeStillRequest(
                seriesTitle: episode.parentTitle ?? episode.title,
                seriesTmdbID: episode.providerIDs["SeriesTmdb"],
                season: season,
                episode: number
            )
        }
        guard !requests.isEmpty else { return }
        await TMDbArtworkResolver.shared.prefetchEpisodeStills(requests)
    }

    /// Episodes the rail should show: the selected season's loaded episodes, or
    /// the series' loose episodes when there are no season containers. Each is
    /// stamped with the series' TMDb id (under `SeriesTmdb`) so episode cards can
    /// resolve the show's backdrop as a thumbnail fallback when the server has no
    /// per-episode still (common for anime via Shoko/AniDB).
    private var currentEpisodes: [MediaItem] {
        let base: [MediaItem]
        if let id = selectedSeasonID, let episodes = viewModel.episodes(for: id) {
            base = episodes
        } else {
            base = seasons.isEmpty ? looseEpisodes : []
        }
        guard let seriesTmdb = series.providerIDs["Tmdb"], !seriesTmdb.isEmpty else { return base }
        return base.map { episode in
            var copy = episode
            if copy.providerIDs["SeriesTmdb"] == nil {
                copy.providerIDs["SeriesTmdb"] = seriesTmdb
            }
            return copy
        }
    }

    /// A representative tech-badge set (best resolution/HDR/audio) derived from
    /// every episode loaded so far. The series/season hero has no media file of
    /// its own, so this summarises the show's peak capabilities — and because it
    /// aggregates across all loaded seasons, it only grows toward the true peak
    /// as more seasons are browsed.
    private var representativeTechnicalBadges: [MediaBadge] {
        let loaded = viewModel.seasonEpisodes.values.flatMap { $0 }
        let episodes = loaded.isEmpty ? looseEpisodes : loaded
        return episodes.representativeTechnicalBadges
    }

    /// Header for the episode rail. A selected season's name is already shown on
    /// its tab/chip above the rail, so the rail itself stays unlabelled to avoid
    /// repeating it. The flat "loose episodes" case (no season tabs) keeps an
    /// "Episodes" header since nothing else names it.
    private var railTitle: String {
        if selectedSeasonID != nil { return "" }
        return seasons.isEmpty ? "Episodes" : ""
    }

    /// The episode the hero's Play button acts on: the focused episode itself, or
    /// the "next up" episode of the current season. `nil` hides the button.
    private var playTarget: MediaItem? {
        if heroItem.kind == .episode { return heroItem }
        return SeriesResume.nextUp(in: currentEpisodes)
    }

    /// The series' trailer action, shown only while the hero is presenting the
    /// series itself (not a focused season/episode), so the Trailer button reads
    /// as belonging to the show. `nil` hides the button.
    private var trailerButtonAction: (() -> Void)? {
        guard heroItem.id == series.id, let trailer = viewModel.trailers.first else { return nil }
        return { onPlay(trailer) }
    }

    /// Picks the season to open on first appearance — the one pre-selected via
    /// "Go to Season"/episode tap if any, otherwise the first season — and
    /// preloads it. When targeting a tapped episode, swaps the hero to the richer
    /// loaded copy of that episode once its season's episodes are available.
    private func prepareInitialSeason() async {
        if let id = selectedSeasonID {
            await viewModel.loadEpisodes(for: id)
            await frontTargetEpisodeIfNeeded(in: id)
            return
        }
        guard let first = seasons.first else {
            await frontTargetEpisodeIfNeeded(in: nil)
            return
        }
        selectedSeasonID = first.id
        await viewModel.loadEpisodes(for: first.id)
        await frontTargetEpisodeIfNeeded(in: first.id)
    }

    /// After episodes load, replace the hero's tapped-episode placeholder with the
    /// fully-loaded episode (richer overview/badges) so the hero and Play target
    /// reflect complete metadata. No-op unless the page is targeting an episode —
    /// a normal open keeps the stable series hero (the Play button still resumes
    /// "next up"), so nothing swaps under the user after load.
    @MainActor
    private func frontTargetEpisodeIfNeeded(in seasonID: String?) async {
        guard let target = initialEpisode else { return }
        let pool = seasonID.flatMap { viewModel.episodes(for: $0) } ?? (seasons.isEmpty ? looseEpisodes : [])
        if let loaded = pool.first(where: { $0.id == target.id }) {
            heroItem = loaded
        }
    }
}

#endif
