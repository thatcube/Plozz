#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The Home screen: Continue Watching, Latest, and library shortcuts.
public struct HomeView: View {
    @State private var viewModel: HomeViewModel
    private var visibility: HomeLibraryVisibilityModel
    private let spoilerSettings: SpoilerSettings
    private let onSelectItem: (MediaItem) -> Void
    private let onPlayItem: (MediaItem) -> Void
    private let onSelectLibrary: (MediaLibrary) -> Void

    @Environment(\.plozzMetrics) private var metrics

    public init(
        viewModel: HomeViewModel,
        visibility: HomeLibraryVisibilityModel,
        spoilerSettings: SpoilerSettings = .default,
        onSelectItem: @escaping (MediaItem) -> Void,
        onPlayItem: @escaping (MediaItem) -> Void,
        onSelectLibrary: @escaping (MediaLibrary) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.visibility = visibility
        self.spoilerSettings = spoilerSettings
        self.onSelectItem = onSelectItem
        self.onPlayItem = onPlayItem
        self.onSelectLibrary = onSelectLibrary
    }

    public var body: some View {
        ContentStateView(
            state: viewModel.state,
            emptyMessage: "Your libraries are empty. Add media on your media server to see it here.",
            onRetry: { Task { await viewModel.load() } },
            loadingContent: { HomeSkeletonView(layout: viewModel.skeletonLayout) }
        ) { content in
            // The screen is a data-driven list of rows. Both this loaded view and
            // the skeleton render from the same ordered `HomeRow`/`HomeRowKind`
            // structure, which keeps them 1:1 and makes the order the single thing
            // a future row-customization feature edits. `HomeRow.rows` also applies
            // per-library Home-visibility to *every* row's items (not just the
            // Libraries tiles), so a hidden library's content is suppressed
            // app-wide; passing the reactive `isVisible` here keeps toggles taking
            // effect on the next render even before any re-fetch settles.
            let rows = HomeRow.rows(for: content) { visibility.isVisible($0) }
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, PlozzTheme.Metrics.screenVerticalPadding)
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
            // Remember the structure we actually rendered (post-visibility) so the
            // next launch's skeleton matches this exact set of rows.
            .task(id: rows.map(\.kind)) { viewModel.rememberLayout(rows.map(\.kind)) }
        }
        .task(id: visibility.visibility.excludedKeys) {
            // First appearance loads; thereafter a change to the hidden-library set
            // re-aggregates so library-scoped providers (Jellyfin) re-fetch with the
            // new visible set. `loadIfNeeded` skips the reload on a bare reappearance
            // (tvOS restarts this `.task` every time Home returns from a pushed
            // detail), so back-navigation no longer flashes the skeleton or resets
            // focus. Providers that tag items inline (Plex) are also filtered live
            // above, so their toggles feel instant even before the reload settles.
            await viewModel.loadIfNeeded(excludedKeys: visibility.visibility.excludedKeys)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            } else {
                Task { await viewModel.load() }
            }
        }
    }

    /// Renders one resolved `HomeRow`. The per-kind wiring (card style, and
    /// whether selecting a card plays it or opens its detail) is exactly what the
    /// view used inline before the row model existed.
    @ViewBuilder
    private func rowView(_ row: HomeRow) -> some View {
        switch row.kind {
        case .continueWatching:
            MediaRowView(title: row.title, items: row.items, style: posterStyle(row.style), spoilerSettings: spoilerSettings, onSelect: onPlayItem)
        case .watchlist, .recentlyAdded:
            MediaRowView(title: row.title, items: row.items, style: posterStyle(row.style), spoilerSettings: spoilerSettings, onSelect: onSelectItem)
        case .libraries:
            librariesRow(row.libraries)
        }
    }

    /// Maps the SwiftUI-free `HomeRowStyle` back to the concrete card style.
    private func posterStyle(_ style: HomeRowStyle) -> PosterCardView.Style {
        switch style {
        case .poster: return .poster
        case .landscape: return .landscape
        }
    }

    private func librariesRow(_ libraries: [AggregatedLibrary]) -> some View {
        VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
            Text("Libraries")
                .font(.system(size: 32, weight: .bold))
                .padding(.leading, PlozzTheme.Metrics.screenPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.cardSpacing) {
                    ForEach(libraries) { aggregated in
                        Button { onSelectLibrary(aggregated.library) } label: {
                            ZStack(alignment: .bottomLeading) {
                                AsyncImage(url: aggregated.library.imageURL) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(.tertiary)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(aggregated.library.title)
                                        .font(.title3).bold()
                                    Text(Self.librarySubtitle(for: aggregated, in: libraries))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .padding(12)
                            }
                            .frame(width: metrics.landscapeWidth, height: metrics.landscapeHeight)
                            .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius))
                            .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.cornerRadius)
                        }
                        .plozzCardButton(cornerRadius: PlozzTheme.Metrics.cornerRadius)
                    }
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.top, metrics.railTopPadding)
                .padding(.bottom, metrics.railVerticalPadding)
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
    }

    /// The tile's secondary line. Library TILES are never merged across servers,
    /// so two same-named libraries (e.g. "Movies" on two Plex servers, or two
    /// Jellyfin logins on one box) appear as distinct tiles — this surfaces enough
    /// of `serverName`/`accountName` to tell them apart. Shows the server name,
    /// and appends the account/user when another visible tile shares that server
    /// name (so the server alone is ambiguous); falls back to the account name
    /// when the server name is missing.
    static func librarySubtitle(for aggregated: AggregatedLibrary, in libraries: [AggregatedLibrary]) -> String {
        let server = aggregated.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = aggregated.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return account }
        let serverIsAmbiguous = libraries.contains {
            $0.id != aggregated.id
                && $0.serverName == aggregated.serverName
                && $0.accountID != aggregated.accountID
        }
        if serverIsAmbiguous, !account.isEmpty, account != server {
            return "\(server) · \(account)"
        }
        return server
    }
}

#endif
