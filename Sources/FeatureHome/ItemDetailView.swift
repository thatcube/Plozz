#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Item detail screen: backdrop hero, metadata, Play/Resume, and children.
public struct ItemDetailView: View {
    @State private var viewModel: ItemDetailViewModel
    private let spoilerSettings: SpoilerSettings
    private let onPlay: (MediaItem) -> Void
    private let onSelectChild: (MediaItem) -> Void
    /// When this detail is a series opened via "Go to Season", the season to
    /// pre-select on the series page. Ignored for non-series items.
    private let initialSeasonID: String?
    /// When a series is opened by tapping one of its episodes (rather than the
    /// series itself), the tapped episode. The series page then opens with this
    /// episode fronted in the hero (Play targets it), its season selected, the
    /// episode row pre-scrolled to it, and focus on the hero Play button.
    private let initialEpisode: MediaItem?
    /// Lands initial focus on the hero Play button (top) rather than letting tvOS
    /// pick a bottom-anchored control in the full-screen hero — which would make
    /// it auto-scroll the page down on arrival. Mirrors `SeriesDetailView`.
    @FocusState private var playFocused: Bool

    public init(
        viewModel: ItemDetailViewModel,
        spoilerSettings: SpoilerSettings = .default,
        onPlay: @escaping (MediaItem) -> Void,
        onSelectChild: @escaping (MediaItem) -> Void,
        initialSeasonID: String? = nil,
        initialEpisode: MediaItem? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.spoilerSettings = spoilerSettings
        self.onPlay = onPlay
        self.onSelectChild = onSelectChild
        self.initialSeasonID = initialSeasonID
        self.initialEpisode = initialEpisode
    }

    public var body: some View {
        ContentStateView(
            state: viewModel.state,
            onRetry: { Task { await viewModel.load() } }
        ) { detail in
            // A season never has its own page: ItemDetailViewModel transparently
            // redirects a season load to its parent series, so by the time we
            // render here a season has become a `.series`. `container` only ever
            // serves movies, episodes, folders and collections.
            if detail.item.kind == .series {
                SeriesDetailView(
                    series: detail.item,
                    seasons: detail.children.filter { $0.kind == .season },
                    looseEpisodes: detail.children.filter { $0.kind == .episode },
                    viewModel: viewModel,
                    spoilerSettings: spoilerSettings,
                    onPlay: onPlay,
                    initialSeasonID: initialSeasonID ?? viewModel.preselectedSeasonID ?? initialEpisode?.seasonID,
                    initialEpisode: initialEpisode
                )
            } else {
                container(detail)
            }
        }
        // Detail is a full-screen sub-page: hide the top tab bar.
        .toolbar(.hidden, for: .tabBar)
        .task { if viewModel.state.value == nil { await viewModel.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            } else {
                Task { await viewModel.reload() }
            }
        }
    }

    /// Layout for non-series detail: a hero plus, for seasons/folders/collections,
    /// a single rail of children. Movies and episodes show just the hero + Play.
    private static let topAnchorID = "item-hero-top"

    private func container(_ detail: ItemDetailViewModel.Detail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    DetailHeroView(
                        item: detail.item,
                        heroHeightFraction: detail.children.isEmpty ? 1.0 : 0.8,
                        spoilerSettings: spoilerSettings,
                        playTitle: isPlayable(detail.item) ? viewModel.playButtonTitle(for: detail.item) : nil,
                        onPlay: isPlayable(detail.item) ? { onPlay(detail.item) } : nil,
                        playProgress: isPlayable(detail.item) ? detail.item.resumeProgressFraction : nil,
                        playRemainingText: isPlayable(detail.item) ? detail.item.resumeRemainingText : nil,
                        onPlayTrailer: viewModel.trailers.first.map { trailer in { onPlay(trailer) } },
                        fallbackTechnicalBadges: detail.children.representativeTechnicalBadges,
                        playButtonFocus: $playFocused
                    )
                    .id(Self.topAnchorID)
                    if !detail.children.isEmpty {
                        MediaRowView(
                            title: childrenTitle(for: detail.item),
                            items: detail.children,
                            style: .landscape,
                            spoilerSettings: spoilerSettings,
                            leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
                            onSelect: onSelectChild
                        )
                    }
                    DetailExtrasView(item: detail.item, leadingInset: PlozzTheme.Metrics.heroLeadingPadding)
                }
                .padding(.bottom, PlozzTheme.Metrics.screenPadding)
                // Cap the whole scroll column to the proposed (safe viewport)
                // width so an over-wide row can't inflate the column past the
                // viewport and pan the page sideways. The hero still bleeds
                // edge-to-edge via its own `.ignoresSafeArea`.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultFocus($playFocused, true)
            // Pin to the top on first load: the Play button is bottom-anchored in
            // the full-screen hero, so initial focus on it makes tvOS auto-scroll
            // the page down. Snap back to the hero top so focus stays on Play.
            .task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.scrollTo(Self.topAnchorID, anchor: .top)
            }
            // Snap back to the hero top whenever Play regains focus (e.g. moving
            // "up" from a children rail), animated so the page glides up smoothly.
            // Without this the movie hero stays scrolled down after tvOS frames
            // the bottom-anchored Play button on first focus.
            .onChange(of: playFocused) { _, focused in
                if focused {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
            // Let the hero bleed into the top overscan inset instead of the
            // ScrollView reserving it as a blank bar above the backdrop.
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func isPlayable(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie, .episode, .video: return true
        default: return false
        }
    }

    private func childrenTitle(for item: MediaItem) -> String {
        "Contents"
    }
}

#endif
