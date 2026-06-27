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
            onRetry: { Task { await viewModel.load() } }
        ) { content in
            let visibleLibraries = content.libraries.filter { visibility.isVisible($0.key) }
            let isLibraryVisible: (String) -> Bool = { visibility.isVisible($0) }
            let continueWatching = content.continueWatching.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
            let watchlist = content.watchlist.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
            let latest = content.latest.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
            ScrollView {
                VStack(alignment: .leading, spacing: PlozzTheme.Metrics.rowSpacing) {
                    MediaRowView(title: "Continue Watching", items: continueWatching, style: .landscape, spoilerSettings: spoilerSettings, onSelect: onPlayItem)
                    if !watchlist.isEmpty {
                        MediaRowView(title: "Watchlist", items: watchlist, spoilerSettings: spoilerSettings, onSelect: onSelectItem)
                    }
                    MediaRowView(title: "Recently Added", items: latest, spoilerSettings: spoilerSettings, onSelect: onSelectItem)

                    if !visibleLibraries.isEmpty {
                        librariesRow(visibleLibraries)
                    }
                }
                .padding(.vertical, 40)
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
        .task(id: visibility.visibility.excludedKeys) {
            // First appearance loads; thereafter a change to the hidden-library set
            // re-aggregates so library-scoped providers (Jellyfin) re-fetch with the
            // new visible set. Providers that tag items inline (Plex) are also
            // filtered live above, so their toggles feel instant even before the
            // reload settles.
            await viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            } else {
                Task { await viewModel.load() }
            }
        }
    }

    private func librariesRow(_ libraries: [AggregatedLibrary]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Libraries")
                .font(.system(size: 32, weight: .bold))
                .padding(.leading, PlozzTheme.Metrics.screenPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PlozzTheme.Metrics.cardSpacing) {
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
                            .frame(width: PlozzTheme.Metrics.landscapeWidth, height: PlozzTheme.Metrics.landscapeHeight)
                            .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius))
                            .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.cornerRadius)
                        }
                        .plozzCardButton(cornerRadius: PlozzTheme.Metrics.cornerRadius)
                    }
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 24)
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
