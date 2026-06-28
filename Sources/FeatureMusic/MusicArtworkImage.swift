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
    /// Optional override for the placeholder icon color — pass
    /// `PlozzCardCaption.subtitleColor(...)` so it flips with focus + reduced
    /// transparency. Falls back to `.secondary` when nil.
    var placeholderColor: Color? = nil

    init(
        url: URL?,
        systemPlaceholder: String = "music.note",
        cornerRadius: CGFloat = 12,
        variant: ArtworkImageVariant = .original,
        showsMediaEdge: Bool = true,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        placeholderColor: Color? = nil
    ) {
        self.url = url
        self.systemPlaceholder = systemPlaceholder
        self.cornerRadius = cornerRadius
        self.variant = variant
        self.showsMediaEdge = showsMediaEdge
        self.asyncFallbackURL = asyncFallbackURL
        self.placeholderColor = placeholderColor
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
            .foregroundStyle(placeholderColor ?? .secondary)
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

/// A focusable square card used across the music grids/rows. Mirrors CoreUI's
/// `PosterCardView` 1:1: the shared liquid-glass lift (theme-aware across
/// dark/OLED/light via `plozzGlassCard`), a focused drop shadow + scale, and
/// title/subtitle that flip to dark ink on the opaque white focus lift (Reduce
/// Transparency on, or pre-tvOS 26) so text never vanishes into the plate.
struct MusicCard: View {
    let artworkURL: URL?
    var systemPlaceholder: String = "music.note"
    let width: CGFloat
    let title: String
    var subtitle: String? = nil
    var asyncFallbackURL: (@Sendable () async -> URL?)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzMetrics) private var metrics

    /// The artwork edge length, scaled by the active UI density so music tiles
    /// grow/shrink in step with the movie/show cards.
    private var scaledWidth: CGFloat { (width * metrics.scale).rounded() }

    init(
        artworkURL: URL?,
        systemPlaceholder: String = "music.note",
        width: CGFloat,
        title: String,
        subtitle: String? = nil,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        action: @escaping () -> Void
    ) {
        self.artworkURL = artworkURL
        self.systemPlaceholder = systemPlaceholder
        self.width = width
        self.title = title
        self.subtitle = subtitle
        self.asyncFallbackURL = asyncFallbackURL
        self.action = action
    }

    /// Title/subtitle colour, flipped to dark ink over a focused card's opaque
    /// "lift" surface. Centralised in `PlozzCardCaption` (CoreUI) so every card
    /// type flips identically.
    private var titleColor: Color {
        PlozzCardCaption.titleColor(isFocused: isFocused, reduceTransparency: reduceTransparency)
    }
    private var subtitleColor: Color {
        PlozzCardCaption.subtitleColor(isFocused: isFocused, reduceTransparency: reduceTransparency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.landscapeCaptionTopSpacing) {
            artwork
                .frame(width: scaledWidth, height: scaledWidth)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Text(subtitle ?? " ")
                    .font(.system(size: metrics.cardSubtitleFontSize))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .opacity(subtitle == nil ? 0 : 1)
            }
            .padding([.horizontal, .bottom], metrics.landscapeCaptionInset)
            .frame(width: scaledWidth, alignment: .leading)
        }
        .padding(metrics.cardInset)
        .plozzGlassCard(cornerRadius: metrics.landscapeCardCornerRadius, isFocused: isFocused)
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.landscapeCardCornerRadius, action: action)
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0.15), radius: isFocused ? 20 : 8, y: isFocused ? 10 : 4)
        .scaleEffect(isFocused ? PlozzTheme.Metrics.mediumFocusedCardScale : 1)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    @ViewBuilder
    private var artwork: some View {
        MusicArtworkImage(
            url: artworkURL,
            systemPlaceholder: systemPlaceholder,
            cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
            asyncFallbackURL: asyncFallbackURL,
            placeholderColor: subtitleColor
        )
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
            title: album.title,
            subtitle: album.subtitleLine,
            asyncFallbackURL: MusicArtworkFallback.albumCover(title: album.title, artist: album.artistName),
            action: action
        )
    }
}

/// A recently-played **song** card for the unified Recently Played rail. Square
/// artwork with a music-note placeholder; tapping plays the track immediately
/// (it routes to playback, not to a detail page like albums/artists do).
struct RecentTrackCard: View {
    let track: MusicTrack
    var width: CGFloat = 260
    let action: () -> Void

    var body: some View {
        MusicCard(
            artworkURL: track.artworkURL,
            systemPlaceholder: "music.note",
            width: width,
            title: track.title,
            subtitle: track.artistName,
            asyncFallbackURL: MusicArtworkFallback.albumCover(title: track.albumTitle ?? track.title, artist: track.artistName),
            action: action
        )
    }
}

struct ArtistCard: View {
    let artist: MusicArtist
    let action: () -> Void

    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        let diameter = metrics.artistTileDiameter
        let slot = diameter + metrics.circleFocusPadding * 2
        CircularFocusTile(
            diameter: diameter,
            focusPadding: metrics.circleFocusPadding,
            action: action,
            avatar: {
                MusicArtworkImage(
                    url: artist.artworkURL,
                    systemPlaceholder: "music.mic",
                    cornerRadius: diameter / 2,
                    asyncFallbackURL: MusicArtworkFallback.artistImage(name: artist.name)
                )
            },
            caption: { isFocused in
                Text(artist.name)
                    .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(width: slot)
            }
        )
    }
}

struct PlaylistCard: View {
    let playlist: MusicPlaylist
    var width: CGFloat = 260
    let action: () -> Void

    var body: some View {
        MusicCard(
            artworkURL: playlist.artworkURL,
            systemPlaceholder: "music.note.list",
            width: width,
            title: playlist.title,
            subtitle: playlist.trackCount.map { "\($0) tracks" },
            action: action
        )
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
