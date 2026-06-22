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
            ScrollView {
                VStack(alignment: .leading, spacing: PlozzTheme.Metrics.rowSpacing) {
                    MediaRowView(title: "Continue Watching", items: content.continueWatching, style: .landscape, spoilerSettings: spoilerSettings, onSelect: onPlayItem)
                    MediaRowView(title: "Recently Added", items: content.latest, spoilerSettings: spoilerSettings, onSelect: onSelectItem)

                    if !visibleLibraries.isEmpty {
                        librariesRow(visibleLibraries)
                    }
                }
                .padding(.vertical, 40)
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
        .task { if viewModel.state.value == nil { await viewModel.load() } }
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
                                    Text(aggregated.serverName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .padding(12)
                            }
                            .frame(width: PlozzTheme.Metrics.landscapeWidth, height: PlozzTheme.Metrics.landscapeHeight)
                            .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius))
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 24)
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
    }
}

#endif
