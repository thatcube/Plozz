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
    @Environment(\.themePalette) private var palette

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
                .fill(palette.fill)
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
/// dark, Pure Black, and light via `plozzGlassCard`), a focused drop shadow + scale, and
/// title/subtitle that flip to dark ink on the opaque white focus lift (Reduce
/// Transparency on, or pre-tvOS 26) so text never vanishes into the plate.
struct MusicCard: View {
    let artworkURL: URL?
    var systemPlaceholder: String = "music.note"
    let width: CGFloat
    let title: String   // l10n:content — album/track name from the server
    var subtitle: String? = nil   // l10n:content — album/track name from the server
    var asyncFallbackURL: (@Sendable () async -> URL?)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzCardFocusStyle) private var focusStyle

    /// The artwork edge length, scaled by the active UI density so music tiles
    /// grow/shrink in step with the movie/show cards.
    private var scaledWidth: CGFloat { (width * metrics.scale).rounded() }

    init(
        artworkURL: URL?,
        systemPlaceholder: String = "music.note",
        width: CGFloat,
        title: String,   // l10n:content — album/track name from the server
        subtitle: String? = nil,   // l10n:content — album/track name from the server
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

    /// Whether the card's surface should read as focused: the glass lift is the
    /// framed card's focus outline, so with the outline off it stays at rest and
    /// the caption keeps its resting ink.
    private var surfaceFocused: Bool { isFocused && focusStyle.drawsFocusOutline }

    /// Title/subtitle colour, flipped to dark ink over a focused card's opaque
    /// "lift" surface. Centralised in `PlozzCardCaption` (CoreUI) so every card
    /// type flips identically.
    private var titleColor: Color {
        PlozzCardCaption.titleColor(isFocused: surfaceFocused, reduceTransparency: reduceTransparency)
    }
    private var subtitleColor: Color {
        PlozzCardCaption.subtitleColor(isFocused: surfaceFocused, reduceTransparency: reduceTransparency)
    }

    var body: some View {
        switch cardStyle {
        case .framed:
            framedCard
        case .borderless:
            borderlessCard
        }
    }

    private var framedCard: some View {
        VStack(alignment: .leading, spacing: metrics.landscapeCaptionTopSpacing) {
            artwork
                .frame(width: scaledWidth, height: scaledWidth)

            VStack(alignment: .leading, spacing: 4) {
                PlozzMarqueeText(
                    text: Text(title),
                    font: .system(size: metrics.cardTitleFontSize, weight: .semibold),
                    color: titleColor,
                    inset: metrics.landscapeCaptionInset,
                    isFocused: isFocused
                )
                PlozzMarqueeText(
                    text: Text(subtitle ?? " "),
                    font: .system(size: metrics.cardSubtitleFontSize),
                    color: subtitleColor,
                    inset: metrics.landscapeCaptionInset,
                    isFocused: isFocused
                )
                .opacity(subtitle == nil ? 0 : 1)
            }
            .padding(.bottom, metrics.landscapeCaptionInset)
            .frame(width: scaledWidth, alignment: .leading)
        }
        .padding(metrics.cardInset)
        .plozzGlassCard(cornerRadius: metrics.landscapeCardCornerRadius, isFocused: surfaceFocused)
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.landscapeCardCornerRadius, action: action)
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0.15), radius: isFocused ? 20 : 8, y: isFocused ? 10 : 4)
        .plozzCardFocusLift(
            isFocused: isFocused,
            cornerRadius: metrics.landscapeCardCornerRadius,
            outlineScale: PlozzTheme.Metrics.mediumFocusedCardScale
        )
        .plozzCardFocusTransition(isFocused: isFocused)
    }

    /// Borderless ("Posters") music card: the square artwork with no glass
    /// surface, rounded at the outer radius, with the shared focus outline + lift
    /// and an on-page caption. Mirrors `PosterCardView`'s borderless card so movie
    /// and music grids look identical.
    private var borderlessCard: some View {
        VStack(alignment: .leading, spacing: borderlessCaptionSpacing) {
            borderlessArtwork
                .frame(width: scaledWidth, height: scaledWidth)
                .plozzFocusHalo(
                    cornerRadius: metrics.landscapeCardCornerRadius,
                    focusScale: PlozzTheme.Metrics.mediumFocusedCardScale,
                    isFocused: isFocused
                )

            BorderlessCardCaption(
                title: Text(verbatim: title),
                subtitle: subtitle,
                horizontalInset: metrics.landscapeCaptionInset,
                isFocused: isFocused
            )
            .frame(width: scaledWidth)
            // Push the caption down on focus with a pure transform (see
            // `borderlessCaptionSpacing`) so the footprint stays fixed and focusing
            // a tile never shifts the grid/row.
            .offset(y: isFocused ? 0 : -captionPush)
        }
        .padding(.horizontal, metrics.borderlessCardSideMargin)
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.landscapeCardCornerRadius, action: action)
        // See PosterCardView.borderlessCard: composite (never rasterize) so the
        // focus halo + scale bloom that extend beyond the bounds aren't clipped.
        .compositingGroup()
        .plozzCardFocusTransition(isFocused: isFocused)
    }

    /// Artwork↔caption gap for the borderless music card. Always reserved at its
    /// focused size (base + density-scaled push); the caption rides up when
    /// unfocused via a transform offset, so the tile's footprint never changes with
    /// focus and neighbours don't move.
    private var borderlessCaptionSpacing: CGFloat {
        metrics.landscapeCaptionTopSpacing + captionPush
    }

    /// How far this card's caption drops on focus, for the active focus style —
    /// the highlight style grows the card further, so the caption clears further.
    private var captionPush: CGFloat {
        metrics.focusCaptionPush(for: focusStyle)
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

    /// Borderless artwork rounds the image itself at the *outer* radius (there's
    /// no glass border to supply it) so it matches the poster borderless look.
    @ViewBuilder
    private var borderlessArtwork: some View {
        MusicArtworkImage(
            url: artworkURL,
            systemPlaceholder: systemPlaceholder,
            cornerRadius: metrics.landscapeCardCornerRadius,
            asyncFallbackURL: asyncFallbackURL,
            placeholderColor: .secondary
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
