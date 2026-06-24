#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit

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
    /// `looseEpisodes` stamped once with `SeriesTmdb` so focus-driven hero updates
    /// don't repeatedly remap huge episode arrays in `body`.
    private let stampedLooseEpisodes: [MediaItem]
    let viewModel: ItemDetailViewModel
    let spoilerSettings: SpoilerSettings
    let onPlay: (MediaItem) -> Void
    /// When the page was opened targeting a specific season, that season's id.
    let initialSeasonID: String?
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
    /// Bumped whenever focus enters the season tab bar. Handed to the episode rail
    /// as its `focusResetToken` so the rail re-arms its entry gate deterministically
    /// when focus has truly left it (gone up to the bar) — rather than inferring it
    /// from a transient `nil` during a fast horizontal hold, which could strand the
    /// focus indicator.
    @State private var episodeRailResetToken = 0
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
        self.stampedLooseEpisodes = Self.stampSeriesTMDb(into: looseEpisodes, series: series)
        self.viewModel = viewModel
        self.spoilerSettings = spoilerSettings
        self.onPlay = onPlay
        self.initialSeasonID = initialSeasonID
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
            // Warm the current season's episode thumbnails as soon as they load, so
            // cards already have their thumbnail when scrolled to rather than
            // visibly fetching it on appear.
            .task(id: stillPrefetchKey) { await prefetchSeasonStills() }
            // Background-warm *every* season's thumbnails the moment the page opens,
            // so switching seasons later is instant (no gray-placeholder flash)
            // rather than fetching that season's stills only once it is selected.
            .task { await prewarmAllSeasons() }
            // The hero mirrors the focused episode via a local copy, so when a
            // watched/watchlist mutation broadcasts (e.g. from the hero's own
            // Watched button), flip the same flags on `heroItem` in place so the
            // visible hero button reflects the new state immediately.
            .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
                guard let mutation = MediaItemMutation.from(note),
                      mutation.itemIDs.contains(heroItem.id) else { return }
                if let played = mutation.played { heroItem.isPlayed = played }
                if let favorite = mutation.favorite { heroItem.isFavorite = favorite }
            }
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
                // Cap the whole scroll column to the proposed (safe viewport)
                // width. The hero backdrop still bleeds edge-to-edge via its own
                // `.ignoresSafeArea`, but its layout footprint — and any over-wide
                // row below (e.g. a long tags strip) — can no longer inflate the
                // column past the viewport, which is what let tvOS pan the page
                // sideways and shove focus off the left edge.
                .frame(maxWidth: .infinity, alignment: .leading)
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
            // Focus has genuinely left the episode rail (it's now on the bar), so
            // tell the rail to re-arm its entry gate for the next down-press.
            episodeRailResetToken += 1
            guard let season = seasons.first(where: { $0.id == id }) else { return }
            select(season)
            // Deliberately *don't* move the hero to the season: focusing the tab bar
            // keeps the page on the episode you were last viewing, so going up and
            // back down stays anchored to that episode rather than the season.
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
        // The episode the hero's Play button acts on — what focus should land on
        // when moving down into the rail, and where the rail is pre-scrolled.
        let target = isTargetingEpisode ? initialEpisode?.id : SeriesResume.nextUp(in: episodes)?.id
        return MediaRowView(
            title: railTitle,
            items: episodes,
            style: .landscape,
            spoilerSettings: spoilerSettings,
            // Keep focus on the hero Play button initially; pre-scroll the rail to
            // the resume/target episode and make it the row's default focus so
            // pressing down from Play lands on *that* episode — wherever it is in
            // the season — rather than the geometrically-nearest card.
            initialFocusID: nil,
            initialScrollID: target,
            defaultFocusID: target,
            focusResetToken: episodeRailResetToken,
            leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
            onFocusChange: { focused in
                if let focused, heroItem.id != focused.id { heroItem = focused }
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

    /// Warms the **currently selected** season so its episode thumbnails are
    /// synchronously seedable on first render (no gray placeholder flash). Runs
    /// whenever the selected season's episodes arrive or change.
    private func prefetchSeasonStills() async {
        if let id = selectedSeasonID {
            await warmSeason(id)
        } else {
            warmPrimaryThumbnails(for: currentEpisodes)
        }
    }

    /// Background-warms *every other* season the moment the page opens, which is
    /// what eliminates the gray-placeholder flash when the user later switches
    /// seasons. For each season we first ensure its episodes are fetched and cached
    /// (so the rail never momentarily shows an empty list on switch) and then warm
    /// + inject each episode's thumbnail ahead of time. Seasons are warmed one at a
    /// time, yielding between them, so a long show never floods the loader or
    /// competes with the on-screen season's art. The currently selected season is
    /// skipped here because `prefetchSeasonStills` already owns it.
    private func prewarmAllSeasons() async {
        for season in seasons where season.id != selectedSeasonID {
            if Task.isCancelled { return }
            await viewModel.loadEpisodes(for: season.id)
            await warmSeason(season.id)
            await Task.yield()
        }
    }

    /// Makes a season's episode thumbnails render with **no gray flash** when its
    /// rail appears, by guaranteeing each card can seed its image *synchronously*
    /// from the decoded cache on first frame.
    ///
    /// Two episode shapes exist:
    ///   • Episodes the server has an image for already expose a seedable candidate
    ///     URL (`posterURL`/`backdropURL`); we just decode it into the cache.
    ///   • Anime (and other) episodes the server has *no* image for would otherwise
    ///     get their still from the asynchronous ``ArtworkRouter`` fallback — a URL
    ///     that is resolved lazily and therefore can **never** be seeded
    ///     synchronously, which is the root of the persistent one-frame gray flash.
    ///     For those we resolve the still here (the real per-episode still, else the
    ///     series hero), decode it, and **inject it as the episode's `posterURL`**
    ///     so it becomes a seedable candidate. The enriched episodes are handed back
    ///     to the view model so the rail re-renders seeding the now-decoded image.
    private func warmSeason(_ seasonID: String) async {
        guard let episodes = viewModel.episodes(for: seasonID) else { return }
        var resolved = episodes
        var changed = false
        var heroResolved = false
        var heroURL: URL?
        for index in resolved.indices {
            if Task.isCancelled { return }
            let episode = resolved[index]
            if let url = episode.artworkCandidates(for: .landscape).first {
                #if canImport(UIKit)
                await ArtworkImageCache.shared.image(for: url)
                #endif
                continue
            }
            guard episode.kind == .episode else { continue }
            // No server image: resolve a real still, falling back to the series
            // hero (resolved once and reused) so every episode is at least covered.
            var still = await ArtworkRouter.shared.artworkURL(.thumbnail, for: episode)
            if still == nil {
                if !heroResolved {
                    heroURL = await ArtworkRouter.shared.artworkURL(.hero, for: series)
                    heroResolved = true
                }
                still = heroURL ?? series.fallbackArtworkURL
            }
            guard let still else { continue }
            #if canImport(UIKit)
            await ArtworkImageCache.shared.image(for: still)
            #endif
            resolved[index].posterURL = still
            changed = true
        }
        if changed {
            viewModel.setEpisodes(resolved, for: seasonID)
        }
    }

    /// Decodes each episode's first displayed landscape candidate (its server
    /// image) into the shared synchronous image cache. Used for the loose-episode
    /// case where there is no season id to enrich.
    private func warmPrimaryThumbnails(for episodes: [MediaItem]) {
        #if canImport(UIKit)
        for episode in episodes {
            guard let url = episode.artworkCandidates(for: .landscape).first else { continue }
            ArtworkImageCache.shared.prefetch(url)
        }
        #endif
    }

    /// Episodes the rail should show: the selected season's loaded episodes, or
    /// the series' loose episodes when there are no season containers.
    private var currentEpisodes: [MediaItem] {
        if let id = selectedSeasonID, let episodes = viewModel.episodes(for: id) {
            return episodes
        }
        return seasons.isEmpty ? stampedLooseEpisodes : []
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
        let pool = seasonID.flatMap { viewModel.episodes(for: $0) } ?? (seasons.isEmpty ? stampedLooseEpisodes : [])
        
        if let target = initialEpisode {
            if let loaded = pool.first(where: { $0.id == target.id }) {
                heroItem = loaded
            }
        } else if initialSeasonID != nil {
            if let target = SeriesResume.nextUp(in: pool) {
                heroItem = target
            }
        }
    }

    /// Adds the owning series' TMDb id to each episode under `SeriesTmdb`, plus the
    /// series' anime ids and an "Anime" genre when the show is anime, once — keeping
    /// per-episode artwork fallback (including the keyless AniList banner for anime)
    /// fully functional without body-time remapping.
    private static func stampSeriesTMDb(into episodes: [MediaItem], series: MediaItem) -> [MediaItem] {
        let seriesTMDbID = series.providerIDs["Tmdb"]
        let animeIDs = series.providerIDs.filter { ContentClassifier.isAnimeProviderIDKey($0.key) }
        let isAnime = ContentClassifier.isAnime(series)
        let hasTMDb = (seriesTMDbID?.isEmpty == false)
        guard hasTMDb || isAnime || !animeIDs.isEmpty else { return episodes }
        return episodes.map { episode in
            var copy = episode
            if let seriesTMDbID, !seriesTMDbID.isEmpty, copy.providerIDs["SeriesTmdb"] == nil {
                copy.providerIDs["SeriesTmdb"] = seriesTMDbID
            }
            for (key, value) in animeIDs where copy.providerIDs[key] == nil {
                copy.providerIDs[key] = value
            }
            if isAnime, !copy.genres.contains(where: { $0.lowercased().contains("anime") }) {
                copy.genres.append("Anime")
            }
            return copy
        }
    }
}

#endif
