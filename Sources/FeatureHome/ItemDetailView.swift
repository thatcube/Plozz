#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Item detail screen: backdrop hero, metadata, Play/Resume, and children.
public struct ItemDetailView: View {
    @State private var viewModel: ItemDetailViewModel
    private let onPlay: (MediaItem) -> Void
    private let onSelectChild: (MediaItem) -> Void

    public init(
        viewModel: ItemDetailViewModel,
        onPlay: @escaping (MediaItem) -> Void,
        onSelectChild: @escaping (MediaItem) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onPlay = onPlay
        self.onSelectChild = onSelectChild
    }

    public var body: some View {
        ContentStateView(
            state: viewModel.state,
            onRetry: { Task { await viewModel.load() } }
        ) { detail in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    hero(detail.item)
                    if !detail.children.isEmpty {
                        MediaRowView(
                            title: childrenTitle(for: detail.item),
                            items: detail.children,
                            style: detail.item.kind == .series ? .poster : .landscape,
                            onSelect: onSelectChild
                        )
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .task { if viewModel.state.value == nil { await viewModel.load() } }
    }

    private func hero(_ item: MediaItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: item.backdropURL ?? item.posterURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.tertiary)
            }
            .frame(height: 720)
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(0.0), .black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            VStack(alignment: .leading, spacing: 16) {
                Text(item.title)
                    .font(.system(size: 64, weight: .bold))
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary)
                }
                if let overview = item.overview {
                    Text(overview)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                if isPlayable(item) {
                    Button {
                        onPlay(item)
                    } label: {
                        Label(viewModel.playButtonTitle(for: item), systemImage: "play.fill")
                            .frame(minWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
            }
            .padding(PlizzTheme.Metrics.screenPadding)
        }
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
}

#endif
