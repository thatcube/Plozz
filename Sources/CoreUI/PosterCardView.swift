#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A focusable poster/landscape card for a `MediaItem`, with artwork, a watched
/// progress bar, and title/subtitle. The standard building block of Home rows
/// and library grids.
public struct PosterCardView: View {
    public enum Style { case poster, landscape }

    private let item: MediaItem
    private let style: Style
    private let action: () -> Void

    public init(item: MediaItem, style: Style = .poster, action: @escaping () -> Void) {
        self.item = item
        self.style = style
        self.action = action
    }

    private var size: CGSize {
        switch style {
        case .poster:
            return CGSize(width: PlizzTheme.Metrics.posterWidth, height: PlizzTheme.Metrics.posterHeight)
        case .landscape:
            return CGSize(width: PlizzTheme.Metrics.landscapeWidth, height: PlizzTheme.Metrics.landscapeHeight)
        }
    }

    private var artworkURL: URL? {
        style == .landscape ? (item.backdropURL ?? item.posterURL) : item.posterURL
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                artwork
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: PlizzTheme.Metrics.cornerRadius))
                    .overlay(alignment: .bottom) { progressBar }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: size.width, alignment: .leading)
            }
        }
        // Native tvOS card styling gives the focus "lift"/parallax for free.
        .buttonStyle(.card)
    }

    @ViewBuilder
    private var artwork: some View {
        AsyncImage(url: artworkURL) { phase in
            switch phase {
            case let .success(image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholder(icon: "film")
            case .empty:
                placeholder(icon: "photo")
            @unknown default:
                placeholder(icon: "photo")
            }
        }
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            Rectangle().fill(.tertiary)
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let percentage = item.playedPercentage, percentage > 0.01, percentage < 0.99 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.4))
                    Rectangle()
                        .fill(.tint)
                        .frame(width: geo.size.width * percentage)
                }
            }
            .frame(height: 8)
        }
    }
}

#endif
