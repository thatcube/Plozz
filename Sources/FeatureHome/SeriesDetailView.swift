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

    /// Which season's episodes the rail is currently showing. Driven by season
    /// tab focus; seeded to the "next up" season on first appearance.
    @State private var selectedSeasonID: String?
    /// The item the hero is currently presenting. Updated as focus moves; it is
    /// never cleared, so moving focus onto a non-previewing control (e.g. the
    /// hero's own Play button) keeps the last meaningful context.
    @State private var heroItem: MediaItem
    @FocusState private var focusedSeasonID: String?
    @Environment(\.themePalette) private var palette

    init(
        series: MediaItem,
        seasons: [MediaItem],
        looseEpisodes: [MediaItem],
        viewModel: ItemDetailViewModel,
        spoilerSettings: SpoilerSettings,
        onPlay: @escaping (MediaItem) -> Void
    ) {
        self.series = series
        self.seasons = seasons
        self.looseEpisodes = looseEpisodes
        self.viewModel = viewModel
        self.spoilerSettings = spoilerSettings
        self.onPlay = onPlay
        _heroItem = State(initialValue: series)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                DetailHeroView(
                    item: heroItem,
                    spoilerSettings: spoilerSettings,
                    playTitle: playTarget.map { viewModel.playButtonTitle(for: $0) },
                    onPlay: playTarget.map { target in { onPlay(target) } }
                )

                if !seasons.isEmpty {
                    seasonTabBar
                }

                episodeRail
            }
            .padding(.bottom, PlozzTheme.Metrics.screenPadding)
        }
        .task { await prepareInitialSeason() }
    }

    // MARK: Season tabs

    private var seasonTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(seasons) { season in
                    seasonChip(season)
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            // Headroom for the focused chip's lift so it is never clipped.
            .padding(.vertical, 12)
        }
        .onChange(of: focusedSeasonID) { _, newValue in
            guard let id = newValue, let season = seasons.first(where: { $0.id == id }) else { return }
            select(season)
            heroItem = season
        }
    }

    /// A small liquid-glass season "pill". Mirrors the player control buttons:
    /// glass surface via `plozzGlassCard` (which honours the active theme and the
    /// Reduce Transparency setting), a focus lift, and an accent ring marking the
    /// season the rail is currently showing.
    private func seasonChip(_ season: MediaItem) -> some View {
        let isFocused = focusedSeasonID == season.id
        let isSelected = selectedSeasonID == season.id
        return Button {
            select(season)
            heroItem = season
        } label: {
            Text(season.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .focused($focusedSeasonID, equals: season.id)
        .focusEffectDisabled()
        .plozzGlassCard(cornerRadius: 100, isFocused: isFocused)
        .overlay {
            if isSelected && !isFocused {
                Capsule().strokeBorder(palette.accent.opacity(0.8), lineWidth: 2)
            }
        }
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
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
            initialFocusID: SeriesResume.nextUp(in: episodes)?.id,
            onFocusChange: { focused in
                if let focused { heroItem = focused }
            },
            onSelect: onPlay
        )
    }

    /// Episodes the rail should show: the selected season's loaded episodes, or
    /// the series' loose episodes when there are no season containers.
    private var currentEpisodes: [MediaItem] {
        if let id = selectedSeasonID, let episodes = viewModel.episodes(for: id) {
            return episodes
        }
        return seasons.isEmpty ? looseEpisodes : []
    }

    private var railTitle: String {
        if let id = selectedSeasonID, let season = seasons.first(where: { $0.id == id }) {
            return season.title
        }
        return "Episodes"
    }

    /// The episode the hero's Play button acts on: the focused episode itself, or
    /// the "next up" episode of the current season. `nil` hides the button.
    private var playTarget: MediaItem? {
        if heroItem.kind == .episode { return heroItem }
        return SeriesResume.nextUp(in: currentEpisodes)
    }

    /// Picks the season to open on first appearance — the one holding the user's
    /// "next up" episode if we can tell, else the first season — and preloads it.
    private func prepareInitialSeason() async {
        guard selectedSeasonID == nil else { return }
        guard let first = seasons.first else { return }
        selectedSeasonID = first.id
        await viewModel.loadEpisodes(for: first.id)
    }
}

#endif
