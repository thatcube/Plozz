#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The Home screen: Continue Watching, Latest, and library shortcuts.
public struct HomeView: View {
    @State private var viewModel: HomeViewModel
    private let onSelectItem: (MediaItem) -> Void
    private let onSelectLibrary: (MediaLibrary) -> Void

    public init(
        viewModel: HomeViewModel,
        onSelectItem: @escaping (MediaItem) -> Void,
        onSelectLibrary: @escaping (MediaLibrary) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onSelectItem = onSelectItem
        self.onSelectLibrary = onSelectLibrary
    }

    public var body: some View {
        ContentStateView(
            state: viewModel.state,
            emptyMessage: "Your libraries are empty. Add media on your Jellyfin server to see it here.",
            onRetry: { Task { await viewModel.load() } }
        ) { content in
            ScrollView {
                VStack(alignment: .leading, spacing: PlozzTheme.Metrics.rowSpacing) {
                    header

                    MediaRowView(title: "Continue Watching", items: content.continueWatching, style: .landscape, onSelect: onSelectItem)
                    MediaRowView(title: "Recently Added", items: content.latest, onSelect: onSelectItem)

                    if !content.libraries.isEmpty {
                        librariesRow(content.libraries)
                    }
                }
                .padding(.vertical, 40)
            }
        }
        .task { if viewModel.state.value == nil { await viewModel.load() } }
    }

    private var header: some View {
        Text("Welcome back, \(viewModel.userName)")
            .font(.largeTitle).bold()
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
    }

    private func librariesRow(_ libraries: [MediaLibrary]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Libraries")
                .font(.title2).bold()
                .padding(.leading, PlozzTheme.Metrics.screenPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PlozzTheme.Metrics.cardSpacing) {
                    ForEach(libraries) { library in
                        Button { onSelectLibrary(library) } label: {
                            ZStack {
                                AsyncImage(url: library.imageURL) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(.tertiary)
                                }
                                Text(library.title)
                                    .font(.title3).bold()
                                    .padding(8)
                                    .background(.ultraThinMaterial, in: Capsule())
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
        }
    }
}

#endif
