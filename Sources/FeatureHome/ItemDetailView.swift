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
            if detail.item.kind == .series {
                SeriesDetailView(
                    series: detail.item,
                    seasons: detail.children.filter { $0.kind == .season },
                    looseEpisodes: detail.children.filter { $0.kind == .episode },
                    viewModel: viewModel,
                    spoilerSettings: spoilerSettings,
                    onPlay: onPlay,
                    initialSeasonID: initialSeasonID ?? initialEpisode?.seasonID,
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
    private func container(_ detail: ItemDetailViewModel.Detail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                DetailHeroView(
                    item: detail.item,
                    spoilerSettings: spoilerSettings,
                    playTitle: isPlayable(detail.item) ? viewModel.playButtonTitle(for: detail.item) : nil,
                    onPlay: isPlayable(detail.item) ? { onPlay(detail.item) } : nil,
                    onPlayTrailer: viewModel.trailers.first.map { trailer in { onPlay(trailer) } },
                    fallbackTechnicalBadges: detail.children.representativeTechnicalBadges
                )
                if !detail.children.isEmpty {
                    MediaRowView(
                        title: childrenTitle(for: detail.item),
                        items: detail.children,
                        style: detail.item.kind == .series ? .poster : .landscape,
                        spoilerSettings: spoilerSettings,
                        initialFocusID: nextUpFocusID(for: detail),
                        leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
                        onSelect: onSelectChild
                    )
                    .mediaItemActionContext(childrenActionContext(for: detail))
                }
                DetailExtrasView(item: detail.item, leadingInset: PlozzTheme.Metrics.heroLeadingPadding)
            }
            .padding(.bottom, PlozzTheme.Metrics.screenPadding)
        }
        // Never clip a focused card's lift, shadow or border.
        .scrollClipDisabled()
        // Let the hero bleed into the top overscan inset instead of the
        // ScrollView reserving it as a blank bar above the backdrop.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// For a season opened directly, the episode rail is an ordered list, so we
    /// supply it as context to enable "mark watched up to here". Other container
    /// kinds (series shows seasons, folders, collections) carry no ordering.
    private func childrenActionContext(for detail: ItemDetailViewModel.Detail) -> MediaItemActionContext {
        guard detail.item.kind == .season else { return .none }
        return MediaItemActionContext(orderedSiblings: detail.children)
    }

    private func isPlayable(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie, .episode, .video: return true
        default: return false
        }
    }

    private func childrenTitle(for item: MediaItem) -> String {
        switch item.kind {
        case .series: return "Seasons"
        case .season: return "Episodes"
        default: return "Contents"
        }
    }

    /// For a series/season, the child the episodes/seasons rail should open
    /// focused on (the "next up" episode). Other container kinds keep default
    /// focus.
    private func nextUpFocusID(for detail: ItemDetailViewModel.Detail) -> String? {
        switch detail.item.kind {
        case .series, .season:
            return SeriesResume.nextUp(in: detail.children)?.id
        default:
            return nil
        }
    }
}

#endif
