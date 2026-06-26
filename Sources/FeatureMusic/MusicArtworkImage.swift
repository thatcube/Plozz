#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Square async artwork for a music node, with a symbol placeholder while
/// loading or when no image exists. Mirrors CoreUI's fallback-image behaviour but
/// is square (album/artist art) rather than poster-shaped.
///
/// The server's own art (`url`) is always tried first. `asyncFallbackURL` is an
/// optional best-effort closure (Deezer artist hero / Cover Art Archive album
/// cover via `ArtworkRouter`) used only when the server ships no art, so the
/// keyless MetadataKit music providers fill gaps without ever overriding the
/// user's library art. Resolved bytes are cached by CoreUI's `ArtworkImageCache`.
struct MusicArtworkImage: View {
    let url: URL?
    var systemPlaceholder: String = "music.note"
    var cornerRadius: CGFloat = 12
    var variant: ArtworkImageVariant = .original
    /// Whether to draw the theme-aware hairline rim around the artwork. Off for
    /// the full-screen player, which wants plain classic rounded corners that
    /// don't shift with the app theme.
    var showsMediaEdge: Bool = true
    var asyncFallbackURL: (@Sendable () async -> URL?)? = nil

    init(
        url: URL?,
        systemPlaceholder: String = "music.note",
        cornerRadius: CGFloat = 12,
        variant: ArtworkImageVariant = .original,
        showsMediaEdge: Bool = true,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil
    ) {
        self.url = url
        self.systemPlaceholder = systemPlaceholder
        self.cornerRadius = cornerRadius
        self.variant = variant
        self.showsMediaEdge = showsMediaEdge
        self.asyncFallbackURL = asyncFallbackURL
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.08))
            FallbackAsyncImage(
                urls: [url].compactMap { $0 },
                variant: variant,
                asyncFallbackURL: asyncFallbackURL
            ) {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .modifier(OptionalMediaEdge(cornerRadius: cornerRadius, enabled: showsMediaEdge))
    }

    private var placeholder: some View {
        Image(systemName: systemPlaceholder)
            .font(.system(size: 44))
            .foregroundStyle(.secondary)
    }
}

/// Applies the shared media-edge rim only when enabled, so callers (the player)
/// can opt out of the theme-aware border and keep plain rounded corners.
private struct OptionalMediaEdge: ViewModifier {
    let cornerRadius: CGFloat
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.plozzMediaEdge(cornerRadius: cornerRadius)
        } else {
            content
        }
    }
}

// MARK: - Cards

/// A focusable square card used across the music grids/rows.
struct MusicCard<Caption: View>: View {
    let artworkURL: URL?
    var systemPlaceholder: String = "music.note"
    var isCircular: Bool = false
    let width: CGFloat
    var asyncFallbackURL: (@Sendable () async -> URL?)? = nil
    let action: () -> Void
    @ViewBuilder var caption: () -> Caption

    init(
        artworkURL: URL?,
        systemPlaceholder: String = "music.note",
        isCircular: Bool = false,
        width: CGFloat,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        action: @escaping () -> Void,
        @ViewBuilder caption: @escaping () -> Caption
    ) {
        self.artworkURL = artworkURL
        self.systemPlaceholder = systemPlaceholder
        self.isCircular = isCircular
        self.width = width
        self.asyncFallbackURL = asyncFallbackURL
        self.action = action
        self.caption = caption
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                artwork
                    .frame(width: width, height: width)
                caption()
                    .frame(width: width, alignment: .leading)
            }
        }
        .plozzCardButton(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius)
    }

    @ViewBuilder
    private var artwork: some View {
        if isCircular {
            MusicArtworkImage(
                url: artworkURL,
                systemPlaceholder: systemPlaceholder,
                cornerRadius: width / 2,
                asyncFallbackURL: asyncFallbackURL
            )
            .clipShape(Circle())
        } else {
            MusicArtworkImage(
                url: artworkURL,
                systemPlaceholder: systemPlaceholder,
                asyncFallbackURL: asyncFallbackURL
            )
        }
    }
}

struct AlbumCard: View {
    let album: MusicAlbum
    var width: CGFloat = 260
    let action: () -> Void

    var body: some View {
        MusicCard(
            artworkURL: album.artworkURL,
            systemPlaceholder: "opticaldisc",
            width: width,
            asyncFallbackURL: MusicArtworkFallback.albumCover(title: album.title, artist: album.artistName),
            action: action
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(album.subtitleLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct ArtistCard: View {
    let artist: MusicArtist
    var width: CGFloat = 240
    let action: () -> Void

    var body: some View {
        MusicCard(
            artworkURL: artist.artworkURL,
            systemPlaceholder: "music.mic",
            isCircular: true,
            width: width,
            asyncFallbackURL: MusicArtworkFallback.artistImage(name: artist.name),
            action: action
        ) {
            Text(artist.name)
                .font(.headline)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
        }
    }
}

struct PlaylistCard: View {
    let playlist: MusicPlaylist
    var width: CGFloat = 260
    let action: () -> Void

    var body: some View {
        MusicCard(artworkURL: playlist.artworkURL, systemPlaceholder: "music.note.list", width: width, action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(1)
                if let count = playlist.trackCount {
                    Text("\(count) tracks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Display helpers

extension MusicAlbum {
    var subtitleLine: String {
        switch (artistName, year) {
        case let (name?, year?): return "\(name) · \(year)"
        case let (name?, nil): return name
        case let (nil, year?): return String(year)
        default: return " "
        }
    }
}
#endif
