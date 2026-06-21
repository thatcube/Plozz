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
    private let spoilerSettings: SpoilerSettings
    private let action: () -> Void

    public init(
        item: MediaItem,
        style: Style = .poster,
        spoilerSettings: SpoilerSettings = .default,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.style = style
        self.spoilerSettings = spoilerSettings
        self.action = action
    }

    private var hideThumbnail: Bool { spoilerSettings.shouldHideThumbnail(for: item) }
    private var hideText: Bool { spoilerSettings.shouldHideText(for: item) }

    private var size: CGSize {
        switch style {
        case .poster:
            return CGSize(width: PlozzTheme.Metrics.posterWidth, height: PlozzTheme.Metrics.posterHeight)
        case .landscape:
            return CGSize(width: PlozzTheme.Metrics.landscapeWidth, height: PlozzTheme.Metrics.landscapeHeight)
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
                    .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius))
                    .overlay(alignment: .bottom) { progressBar }

                VStack(alignment: .leading, spacing: 2) {
                    Text(hideText ? spoilerSettings.maskedTitle(for: item) : item.title)
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
        if hideThumbnail {
            switch spoilerSettings.mode {
            case .blur:
                realArtwork
                    .blur(radius: 28)
                    .overlay { spoilerBadge }
            case .placeholder:
                placeholderArtwork
            }
        } else {
            realArtwork
        }
    }

    @ViewBuilder
    private var realArtwork: some View {
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

    /// Spoiler-safe art for `.placeholder` mode: series fan-art (never the real
    /// episode image) with the episode number, so no episode frame is fetched.
    @ViewBuilder
    private var placeholderArtwork: some View {
        ZStack {
            AsyncImage(url: item.backdropURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [.indigo.opacity(0.6), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            Rectangle().fill(.black.opacity(0.45))
            VStack(spacing: 6) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.85))
                Text(spoilerSettings.maskedTitle(for: item))
                    .font(.title3).bold()
                    .foregroundStyle(.white)
            }
        }
    }

    private var spoilerBadge: some View {
        Image(systemName: "eye.slash.fill")
            .font(.system(size: 30))
            .foregroundStyle(.white)
            .padding(14)
            .background(.black.opacity(0.5), in: Circle())
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
