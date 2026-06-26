#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

// MARK: - Landing

struct MusicLandingView: View {
    @State var viewModel: MusicLandingViewModel
    let onSelectRoute: (MusicRoute) -> Void
    var layout: MusicLandingLayout = .default

    var body: some View {
        ContentStateView(state: viewModel.state, emptyMessage: "No music found in your libraries.", onRetry: { Task { await viewModel.load() } }) { content in
            ScrollView {
                VStack(alignment: .leading, spacing: PlozzTheme.Metrics.rowSpacing) {
                    // The page is composed by iterating the data-driven layout, so
                    // reordering or hiding a section is a value change, not a rewrite.
                    ForEach(layout.visibleSections, id: \.self) { section in
                        sectionView(section, content: content)
                    }
                }
                .padding(.vertical, PlozzTheme.Metrics.rowSpacing)
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
        .task { if case .idle = viewModel.state { await viewModel.load() } }
    }

    @ViewBuilder
    private func sectionView(_ section: MusicLandingSection, content: MusicLandingViewModel.Content) -> some View {
        switch section {
        case .recentlyPlayed:
            if !content.recentlyPlayed.isEmpty {
                MusicRow(title: "Recently Played") {
                    ForEach(content.recentlyPlayed) { album in
                        AlbumCard(album: album) { onSelectRoute(.album(album)) }
                    }
                }
            }
        case .browse:
            entryTiles
        case .albums:
            if !content.albums.isEmpty {
                MusicRow(title: "Albums", seeAll: { onSelectRoute(.grid(.album)) }) {
                    ForEach(content.albums) { album in
                        AlbumCard(album: album) { onSelectRoute(.album(album)) }
                    }
                }
            }
        case .artists:
            if !content.artists.isEmpty {
                MusicRow(title: "Artists", seeAll: { onSelectRoute(.grid(.artist)) }) {
                    ForEach(content.artists) { artist in
                        ArtistCard(artist: artist) { onSelectRoute(.artist(artist)) }
                    }
                }
            }
        case .playlists:
            if !content.playlists.isEmpty {
                MusicRow(title: "Playlists", seeAll: { onSelectRoute(.grid(.playlist)) }) {
                    ForEach(content.playlists) { playlist in
                        PlaylistCard(playlist: playlist) { onSelectRoute(.playlist(playlist)) }
                    }
                }
            }
        }
    }

    private var entryTiles: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browse")
                .font(.system(size: 32, weight: .bold))
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 28) {
                    EntryTile(title: "Artists", icon: "music.mic") { onSelectRoute(.grid(.artist)) }
                    EntryTile(title: "Albums", icon: "opticaldisc") { onSelectRoute(.grid(.album)) }
                    EntryTile(title: "Playlists", icon: "music.note.list") { onSelectRoute(.grid(.playlist)) }
                    EntryTile(title: "Genres", icon: "guitars") { onSelectRoute(.grid(.genre)) }
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 12)
            }
            // Never clip a focused tile's lift, shadow or border.
            .scrollClipDisabled()
        }
    }
}

private struct EntryTile: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor.gradient)
                Text(title).font(.headline)
            }
            .frame(width: 280, height: 160)
        }
        .plozzCardButton(cornerRadius: PlozzTheme.Metrics.cornerRadius)
    }
}

/// A horizontal rail with a title and an optional "See All".
private struct MusicRow<Content: View>: View {
    let title: String
    var seeAll: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.system(size: 32, weight: .bold))
                Spacer()
                if let seeAll {
                    Button("See All", action: seeAll)
                        .buttonStyle(.plain)
                        .font(.headline)
                }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: PlozzTheme.Metrics.cardSpacing) {
                    content()
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, PlozzTheme.Metrics.railVerticalPadding)
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
    }
}

// MARK: - Grid

struct MusicGridView: View {
    @State var viewModel: MusicGridViewModel
    let controller: AudioPlaybackController
    let onSelectRoute: (MusicRoute) -> Void

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: PlozzTheme.Metrics.gridSpacing)]

    var body: some View {
        ContentStateView(state: viewModel.state, emptyMessage: emptyMessage, onRetry: { Task { await viewModel.loadMore() } }) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: PlozzTheme.Metrics.rowSpacing) {
                    Text(title)
                        .font(.system(size: 48, weight: .bold))
                        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                        .padding(.top, PlozzTheme.Metrics.rowSpacing)

                    LazyVGrid(columns: columns, spacing: PlozzTheme.Metrics.rowSpacing) {
                        content
                    }
                    .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                    if viewModel.hasMore {
                        ProgressView()
                            .onAppear { Task { await viewModel.loadMore() } }
                            .padding()
                    }
                }
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
        .task { await viewModel.loadFirstPageIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.kind {
        case .album:
            ForEach(viewModel.albums) { album in
                AlbumCard(album: album) { onSelectRoute(.album(album)) }
            }
        case .artist:
            ForEach(viewModel.artists) { artist in
                ArtistCard(artist: artist) { onSelectRoute(.artist(artist)) }
            }
        case .playlist:
            ForEach(viewModel.playlists) { playlist in
                PlaylistCard(playlist: playlist) { onSelectRoute(.playlist(playlist)) }
            }
        case .genre:
            ForEach(viewModel.genres) { genre in
                GenreCard(genre: genre) { onSelectRoute(.grid(.album)) }
            }
        case .track:
            EmptyView()
        }
    }

    private var title: String {
        switch viewModel.kind {
        case .album: return "Albums"
        case .artist: return "Artists"
        case .playlist: return "Playlists"
        case .genre: return "Genres"
        case .track: return "Tracks"
        }
    }

    private var emptyMessage: String { "Nothing here yet." }
}

private struct GenreCard: View {
    let genre: MusicGenre
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack {
                Image(systemName: "guitars")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor.gradient)
                Text(genre.name).font(.headline).lineLimit(1)
            }
            .frame(width: 280, height: 160)
        }
        .plozzCardButton(cornerRadius: PlozzTheme.Metrics.cornerRadius)
    }
}

// MARK: - Artist detail

struct ArtistDetailView: View {
    @State var viewModel: ArtistDetailViewModel
    let onSelectAlbum: (MusicAlbum) -> Void

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: PlozzTheme.Metrics.gridSpacing)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PlozzTheme.Metrics.rowSpacing) {
                HStack(spacing: 32) {
                    MusicArtworkImage(
                        url: viewModel.artist.artworkURL,
                        systemPlaceholder: "music.mic",
                        cornerRadius: 130,
                        asyncFallbackURL: MusicArtworkFallback.artistImage(name: viewModel.artist.name)
                    )
                        .clipShape(Circle())
                        .frame(width: 260, height: 260)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(viewModel.artist.name).font(.system(size: 56, weight: .bold))
                        if !viewModel.artist.genres.isEmpty {
                            Text(viewModel.artist.genres.joined(separator: " · "))
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)

                Text("Albums").font(.system(size: 32, weight: .bold))
                    .padding(.horizontal, PlozzTheme.Metrics.screenPadding)

                LazyVGrid(columns: columns, spacing: PlozzTheme.Metrics.rowSpacing) {
                    ForEach(viewModel.albums) { album in
                        AlbumCard(album: album) { onSelectAlbum(album) }
                    }
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            }
            .padding(.vertical, PlozzTheme.Metrics.rowSpacing)
        }
        .scrollClipDisabled()
        .task { await viewModel.load() }
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    @State var viewModel: AlbumDetailViewModel
    let controller: AudioPlaybackController

    var body: some View {
        MusicDetailLayout(
            tracks: viewModel.tracks,
            artworkFallback: viewModel.album.artworkURL,
            nowPlayingTrackID: controller.currentTrack?.id,
            isPlaying: controller.isPlaying,
            onPlayTrack: { play(from: $0) }
        ) {
            infoColumn
        }
        .task { await viewModel.load() }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            MusicArtworkImage(
                url: viewModel.album.artworkURL,
                systemPlaceholder: "opticaldisc",
                asyncFallbackURL: MusicArtworkFallback.albumCover(
                    title: viewModel.album.title,
                    artist: viewModel.album.artistName
                )
            )
                .frame(width: 360, height: 360)
            Text(viewModel.album.title).font(.system(size: 40, weight: .bold)).lineLimit(3)
            Text(viewModel.album.subtitleLine).font(.title3).foregroundStyle(.secondary).lineLimit(2)
            if let count = viewModel.album.trackCount {
                Text("\(count) tracks · \(MusicFormat.duration(viewModel.album.totalDuration))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            PlayShuffleButtons(
                isEmpty: viewModel.tracks.isEmpty,
                onPlay: { play(from: nil) },
                onShuffle: { shuffle() }
            )
            .padding(.top, 8)
        }
    }

    private func play(from track: MusicTrack?) {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        let start = track.flatMap { t in viewModel.tracks.firstIndex(where: { $0.id == t.id }) } ?? 0
        controller.play(
            tracks: viewModel.tracks,
            startIndex: start,
            resolveStreamURL: streamURLResolver(for: provider),
            resolveLyrics: lyricsResolver(for: provider)
        )
    }

    private func shuffle() {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        controller.playShuffled(
            tracks: viewModel.tracks,
            resolveStreamURL: streamURLResolver(for: provider),
            resolveLyrics: lyricsResolver(for: provider)
        )
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    @State var viewModel: PlaylistDetailViewModel
    let controller: AudioPlaybackController

    var body: some View {
        MusicDetailLayout(
            tracks: viewModel.tracks,
            artworkFallback: viewModel.playlist.artworkURL,
            showArtist: true,
            nowPlayingTrackID: controller.currentTrack?.id,
            isPlaying: controller.isPlaying,
            onPlayTrack: { play(from: $0) }
        ) {
            infoColumn
        }
        .task { await viewModel.load() }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            MusicArtworkImage(url: viewModel.playlist.artworkURL, systemPlaceholder: "music.note.list")
                .frame(width: 360, height: 360)
            Text(viewModel.playlist.title).font(.system(size: 40, weight: .bold)).lineLimit(3)
            Text("\(viewModel.tracks.count) tracks").font(.title3).foregroundStyle(.secondary)
            PlayShuffleButtons(
                isEmpty: viewModel.tracks.isEmpty,
                onPlay: { play(from: nil) },
                onShuffle: { shuffle() }
            )
            .padding(.top, 8)
        }
    }

    private func play(from track: MusicTrack?) {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        let start = track.flatMap { t in viewModel.tracks.firstIndex(where: { $0.id == t.id }) } ?? 0
        controller.play(
            tracks: viewModel.tracks,
            startIndex: start,
            resolveStreamURL: streamURLResolver(for: provider),
            resolveLyrics: lyricsResolver(for: provider)
        )
    }

    private func shuffle() {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        controller.playShuffled(
            tracks: viewModel.tracks,
            resolveStreamURL: streamURLResolver(for: provider),
            resolveLyrics: lyricsResolver(for: provider)
        )
    }
}

// MARK: - Shared subviews

struct PlayShuffleButtons: View {
    let isEmpty: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill").padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isEmpty)

            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "shuffle").padding(.horizontal, 12)
            }
            .buttonStyle(.bordered)
            .disabled(isEmpty)
        }
    }
}

/// Shared album/playlist detail layout: a fixed info column on the left
/// (artwork, title, metadata, play/shuffle) and a scrollable track list on the
/// right. Keeping the track list on its own side stops it from fighting tvOS's
/// vertical focus when paging through a long album.
struct MusicDetailLayout<InfoColumn: View>: View {
    let tracks: [MusicTrack]
    var artworkFallback: URL?
    var showArtist: Bool = false
    var nowPlayingTrackID: String? = nil
    var isPlaying: Bool = false
    let onPlayTrack: (MusicTrack) -> Void
    @ViewBuilder var info: InfoColumn

    var body: some View {
        GeometryReader { geo in
            // Give the album/playlist info column ~a third of the screen so the
            // Play and Shuffle buttons fit comfortably side by side.
            let infoWidth = max(380, geo.size.width * 0.33)
            HStack(alignment: .top, spacing: 56) {
                info
                    .frame(width: infoWidth, alignment: .leading)
                ScrollView {
                    TrackListView(
                        tracks: tracks,
                        artworkFallback: artworkFallback,
                        showArtist: showArtist,
                        nowPlayingTrackID: nowPlayingTrackID,
                        isPlaying: isPlaying,
                        onPlayTrack: onPlayTrack
                    )
                    .padding(.bottom, 40)
                }
                .scrollClipDisabled()
            }
            .padding(PlozzTheme.Metrics.screenPadding)
        }
    }
}

struct TrackListView: View {
    let tracks: [MusicTrack]
    var artworkFallback: URL?
    var showArtist: Bool = false
    /// The id of the track currently loaded in the player (if any), so the row
    /// shows an animated equalizer instead of its track number.
    var nowPlayingTrackID: String? = nil
    /// Whether the player is actively playing (vs paused) — drives whether the
    /// equalizer bars animate or sit still.
    var isPlaying: Bool = false
    let onPlayTrack: (MusicTrack) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                let isCurrent = track.id == nowPlayingTrackID
                Button { onPlayTrack(track) } label: {
                    HStack(spacing: 20) {
                        Group {
                            if isCurrent {
                                NowPlayingEqualizer(isAnimating: isPlaying)
                            } else {
                                Text(track.trackNumber.map(String.init) ?? "\(index + 1)")
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 44, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.headline)
                                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                .lineLimit(1)
                            if showArtist, let artist = track.artistName {
                                Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(MusicFormat.duration(track.duration))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 22)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(TrackRowButtonStyle())
                .focusEffectDisabled()
            }
        }
    }
}

/// Focus treatment for a track row: a soft glass highlight, a hairline accent
/// rim and a gentle lift when focused — matching the app's card focus language
/// without the heavy white tvOS focus plate.
private struct TrackRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            configuration.label
                .background {
                    shape
                        .fill(.thinMaterial)
                        .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
                        .opacity(isFocused ? 1 : 0)
                }
                .scaleEffect(isFocused ? (configuration.isPressed ? 1.0 : 1.02) : 1)
                .shadow(color: .black.opacity(isFocused ? 0.28 : 0), radius: 16, y: 8)
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// A small set of bars that animate up and down like a music equalizer, marking
/// the track currently playing in a list. Bars freeze (mid-height) when paused.
struct NowPlayingEqualizer: View {
    var isAnimating: Bool
    private let barCount = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: height(bar: i, at: t))
                }
            }
            .frame(height: 24, alignment: .bottom)
        }
    }

    private func height(bar i: Int, at t: TimeInterval) -> CGFloat {
        guard isAnimating else { return 9 }
        let speed = 6.0
        let phase = Double(i) * 0.8
        let v = (sin(t * speed + phase) + 1) / 2 // 0...1
        return 5 + CGFloat(v) * 17 // 5...22
    }
}
#endif
