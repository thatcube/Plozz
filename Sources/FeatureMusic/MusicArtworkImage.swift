#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Square async artwork for a music node, with a symbol placeholder while
/// loading or when no image exists. Mirrors CoreUI's fallback-image behaviour but
/// is square (album/artist art) rather than poster-shaped.
struct MusicArtworkImage: View {
    let url: URL?
    var systemPlaceholder: String = "music.note"
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.08))
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        ProgressView()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: systemPlaceholder)
            .font(.system(size: 44))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Cards

/// A focusable square card used across the music grids/rows.
struct MusicCard<Caption: View>: View {
    let artworkURL: URL?
    var systemPlaceholder: String = "music.note"
    var isCircular: Bool = false
    let width: CGFloat
    let action: () -> Void
    @ViewBuilder var caption: () -> Caption

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
            MusicArtworkImage(url: artworkURL, systemPlaceholder: systemPlaceholder, cornerRadius: width / 2)
                .clipShape(Circle())
        } else {
            MusicArtworkImage(url: artworkURL, systemPlaceholder: systemPlaceholder)
        }
    }
}

struct AlbumCard: View {
    let album: MusicAlbum
    var width: CGFloat = 260
    let action: () -> Void

    var body: some View {
        MusicCard(artworkURL: album.artworkURL, systemPlaceholder: "opticaldisc", width: width, action: action) {
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
        MusicCard(artworkURL: artist.artworkURL, systemPlaceholder: "music.mic", isCircular: true, width: width, action: action) {
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
