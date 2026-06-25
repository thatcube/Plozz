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

    /// This device's capabilities, used to drive the smart default version and
    /// the per-version Direct Play / Transcode prediction in the picker.
    private let capabilities: MediaCapabilities
    /// Persists the user's per-title preferred version (creative addition), so a
    /// title reopens on the version they last chose rather than the default.
    private let versionPreferences: VersionPreferenceStoring
    /// The user's explicit version override for this visit. `nil` means "use the
    /// remembered preference, else the smart recommended default".
    @State private var versionOverride: String?
    /// The user's explicit server override for this visit (an `Account.id`). `nil`
    /// means "use the cross-server best-source default". Cleared sources reset it.
    @State private var sourceOverride: String?

    public init(
        viewModel: ItemDetailViewModel,
        spoilerSettings: SpoilerSettings = .default,
        onPlay: @escaping (MediaItem) -> Void,
        onSelectChild: @escaping (MediaItem) -> Void,
        initialSeasonID: String? = nil,
        initialEpisode: MediaItem? = nil,
        capabilities: MediaCapabilities = .detected(),
        versionPreferences: VersionPreferenceStoring = VersionPreferenceStore()
    ) {
        _viewModel = State(initialValue: viewModel)
        self.spoilerSettings = spoilerSettings
        self.onPlay = onPlay
        self.onSelectChild = onSelectChild
        self.initialSeasonID = initialSeasonID
        self.initialEpisode = initialEpisode
        self.capabilities = capabilities
        self.versionPreferences = versionPreferences
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
                    onSelectServer: { source in onSelectChild(detail.item.selectingSource(source)) },
                    initialSeasonID: initialSeasonID ?? viewModel.preselectedSeasonID ?? initialEpisode?.seasonID,
                    initialEpisode: initialEpisode
                )
            } else {
                container(detail)
            }
        }
        // Detail is a full-screen sub-page: hide the top tab bar.
        .toolbar(.hidden, for: .tabBar)
        // Always run load(), even when the page was seeded with the tapped list
        // item for instant first paint. The seed only paints a hero; load() must
        // still fetch the full detail AND its children (seasons/episodes). Skipping
        // it for seeded opens stranded series pages with no seasons/episodes/Play
        // button. load() guards against flashing `.loading` over a seeded hero.
        .task { await viewModel.load() }
        .onDisappear { viewModel.suspendEnrichment() }
        .onAppear { viewModel.resumeEnrichmentIfNeeded() }
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
        let sources = viewModel.sources
        let effectiveSource = effectiveSource(for: detail.item, sources: sources)
        let effectiveVersions = effectiveVersions(for: detail.item, source: effectiveSource)
        let effectiveVersionID = effectiveVersionID(for: detail.item, in: effectiveVersions)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    DetailHeroView(
                        item: detail.item,
                        heroHeightFraction: detail.children.isEmpty ? 1.0 : 0.8,
                        spoilerSettings: spoilerSettings,
                        playTitle: isPlayable(detail.item) ? viewModel.playButtonTitle(for: detail.item) : nil,
                        onPlay: isPlayable(detail.item) ? { onPlay(playItem(for: detail.item, source: effectiveSource, versionID: effectiveVersionID)) } : nil,
                        playProgress: isPlayable(detail.item) ? detail.item.resumeProgressFraction : nil,
                        playRemainingText: isPlayable(detail.item) ? detail.item.resumeRemainingText : nil,
                        onPlayTrailer: viewModel.trailers.first.map { trailer in { onPlay(trailer) } },
                        versions: effectiveVersions,
                        selectedVersionID: effectiveVersionID,
                        capabilities: capabilities,
                        onSelectVersion: { id in selectVersion(id, for: detail.item) },
                        sources: sources,
                        selectedSourceAccountID: effectiveSource?.accountID,
                        onSelectSource: sources.count > 1 ? { id in selectSource(id) } : nil,
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

    /// The version id `Play` should target right now: the user's in-session
    /// override, else their remembered per-title preference (if still offered),
    /// else the smart capability-aware recommended default. `nil` when the chosen
    /// source has no selectable versions (server picks). Computed against the
    /// *effective source's* versions so switching servers re-defaults correctly.
    private func effectiveVersionID(for item: MediaItem, in versions: [MediaVersion]) -> String? {
        guard versions.count > 1 else { return nil }
        if let versionOverride, versions.contains(where: { $0.id == versionOverride }) {
            return versionOverride
        }
        let remembered = versionPreferences.preferredVersionID(forTitle: versionPreferenceKey(for: item))
        if let remembered, versions.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return versions.recommendedSelection(for: capabilities)?.id
    }

    /// The server `Play` should target right now: the user's in-session server
    /// override, else the default source — which honors the **origin** when the
    /// detail was opened from a library tile (that library's server), otherwise
    /// the cross-server best-source default (highest-quality Direct-Play option
    /// this device can play) — else the primary. `nil` for a single-server title
    /// (no server picker; legacy version-only flow).
    private func effectiveSource(for item: MediaItem, sources: [MediaSourceRef]) -> MediaSourceRef? {
        guard sources.count > 1 else { return nil }
        if let sourceOverride, let match = sources.first(where: { $0.accountID == sourceOverride }) {
            return match
        }
        if let selection = CrossSourceSelector.selection(
            from: sources,
            capabilities: capabilities,
            preferredAccountID: viewModel.originSourceAccountID
        ) {
            return selection.source
        }
        return sources.first
    }

    /// The versions to offer in the version picker: the chosen server's files when
    /// a source is selected (empty until that server's detail resolves → server
    /// default plays), else the loaded item's own versions (single-server flow).
    private func effectiveVersions(for item: MediaItem, source: MediaSourceRef?) -> [MediaVersion] {
        guard let source else { return item.versions }
        return source.versions
    }

    /// Builds the retargeted item `Play` should launch: when a cross-server source
    /// is chosen, the item is repointed to that server's id/versions/watch-state
    /// (and version, if any); otherwise the legacy single-server version select.
    private func playItem(for item: MediaItem, source: MediaSourceRef?, versionID: String?) -> MediaItem {
        if let source {
            return item.selectingSource(source, versionID: versionID)
        }
        return item.selectingVersion(versionID)
    }

    /// Records the user's server choice for this visit and clears the version
    /// override so the newly-selected server re-defaults to its own best version.
    private func selectSource(_ accountID: String) {
        sourceOverride = accountID
        versionOverride = nil
    }

    /// Records the user's version choice for this visit and remembers it for next
    /// time, keyed per title (per series for an episode).
    private func selectVersion(_ id: String, for item: MediaItem) {
        versionOverride = id
        versionPreferences.setPreferredVersionID(id, forTitle: versionPreferenceKey(for: item))
    }

    /// Stable key for the per-title version preference. Episodes share their
    /// series' key so a whole show remembers one preferred version.
    private func versionPreferenceKey(for item: MediaItem) -> String {
        item.seriesID ?? item.id
    }
}

#endif
