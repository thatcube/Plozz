#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

// MARK: - Landing

struct MusicLandingView: View {
    @State var viewModel: MusicLandingViewModel
    let onSelectRoute: (MusicRoute) -> Void

    var body: some View {
        ContentStateView(state: viewModel.state, emptyMessage: "No music found in your libraries.", onRetry: { Task { await viewModel.load() } }) { content in
            ScrollView {
                VStack(alignment: .leading, spacing: PlozzTheme.Metrics.rowSpacing) {
                    entryTiles

                    if !content.albums.isEmpty {
                        MusicRow(title: "Albums", seeAll: { onSelectRoute(.grid(.album)) }) {
                            ForEach(content.albums) { album in
                                AlbumCard(album: album) { onSelectRoute(.album(album)) }
                            }
                        }
                    }
                    if !content.artists.isEmpty {
                        MusicRow(title: "Artists", seeAll: { onSelectRoute(.grid(.artist)) }) {
                            ForEach(content.artists) { artist in
                                ArtistCard(artist: artist) { onSelectRoute(.artist(artist)) }
                            }
                        }
                    }
                    if !content.playlists.isEmpty {
                        MusicRow(title: "Playlists", seeAll: { onSelectRoute(.grid(.playlist)) }) {
                            ForEach(content.playlists) { playlist in
                                PlaylistCard(playlist: playlist) { onSelectRoute(.playlist(playlist)) }
                            }
                        }
                    }
                }
                .padding(.vertical, PlozzTheme.Metrics.rowSpacing)
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
        .navigationTitle("Music")
        .task { if case .idle = viewModel.state { await viewModel.load() } }
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
                Image(systemName: icon).font(.system(size: 44))
                Text(title).font(.headline)
            }
            .frame(width: 280, height: 160)
        }
        .buttonStyle(.card)
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
                LazyVGrid(columns: columns, spacing: PlozzTheme.Metrics.rowSpacing) {
                    content
                }
                .padding(PlozzTheme.Metrics.screenPadding)
                if viewModel.hasMore {
                    ProgressView()
                        .onAppear { Task { await viewModel.loadMore() } }
                        .padding()
                }
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
        .navigationTitle(title)
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
                Image(systemName: "guitars").font(.system(size: 40))
                Text(genre.name).font(.headline).lineLimit(1)
            }
            .frame(width: 280, height: 160)
        }
        .buttonStyle(.card)
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
                    MusicArtworkImage(url: viewModel.artist.artworkURL, systemPlaceholder: "music.mic", cornerRadius: 130)
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
        .navigationTitle(viewModel.artist.name)
        .scrollClipDisabled()
        .task { await viewModel.load() }
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    @State var viewModel: AlbumDetailViewModel
    let controller: AudioPlaybackController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                TrackListView(
                    tracks: viewModel.tracks,
                    artworkFallback: viewModel.album.artworkURL,
                    onPlayTrack: { play(from: $0) }
                )
            }
            .padding(PlozzTheme.Metrics.screenPadding)
        }
        .navigationTitle(viewModel.album.title)
        .scrollClipDisabled()
        .task { await viewModel.load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 32) {
            MusicArtworkImage(url: viewModel.album.artworkURL, systemPlaceholder: "opticaldisc")
                .frame(width: 320, height: 320)
            VStack(alignment: .leading, spacing: 14) {
                Text(viewModel.album.title).font(.system(size: 52, weight: .bold)).lineLimit(2)
                Text(viewModel.album.subtitleLine).font(.title3).foregroundStyle(.secondary)
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
            Spacer()
        }
    }

    private func play(from track: MusicTrack?) {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        let start = track.flatMap { t in viewModel.tracks.firstIndex(where: { $0.id == t.id }) } ?? 0
        controller.play(
            tracks: viewModel.tracks,
            startIndex: start,
            resolveStreamURL: streamURLResolver(for: provider)
        )
    }

    private func shuffle() {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        controller.playShuffled(tracks: viewModel.tracks, resolveStreamURL: streamURLResolver(for: provider))
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    @State var viewModel: PlaylistDetailViewModel
    let controller: AudioPlaybackController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                TrackListView(
                    tracks: viewModel.tracks,
                    artworkFallback: viewModel.playlist.artworkURL,
                    showArtist: true,
                    onPlayTrack: { play(from: $0) }
                )
            }
            .padding(PlozzTheme.Metrics.screenPadding)
        }
        .navigationTitle(viewModel.playlist.title)
        .scrollClipDisabled()
        .task { await viewModel.load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 32) {
            MusicArtworkImage(url: viewModel.playlist.artworkURL, systemPlaceholder: "music.note.list")
                .frame(width: 320, height: 320)
            VStack(alignment: .leading, spacing: 14) {
                Text(viewModel.playlist.title).font(.system(size: 52, weight: .bold)).lineLimit(2)
                Text("\(viewModel.tracks.count) tracks").font(.title3).foregroundStyle(.secondary)
                PlayShuffleButtons(
                    isEmpty: viewModel.tracks.isEmpty,
                    onPlay: { play(from: nil) },
                    onShuffle: { shuffle() }
                )
                .padding(.top, 8)
            }
            Spacer()
        }
    }

    private func play(from track: MusicTrack?) {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        let start = track.flatMap { t in viewModel.tracks.firstIndex(where: { $0.id == t.id }) } ?? 0
        controller.play(tracks: viewModel.tracks, startIndex: start, resolveStreamURL: streamURLResolver(for: provider))
    }

    private func shuffle() {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        controller.playShuffled(tracks: viewModel.tracks, resolveStreamURL: streamURLResolver(for: provider))
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

struct TrackListView: View {
    let tracks: [MusicTrack]
    var artworkFallback: URL?
    var showArtist: Bool = false
    let onPlayTrack: (MusicTrack) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button { onPlayTrack(track) } label: {
                    HStack(spacing: 20) {
                        Text(track.trackNumber.map(String.init) ?? "\(index + 1)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.headline).lineLimit(1)
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
                    .padding(.horizontal, 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif
