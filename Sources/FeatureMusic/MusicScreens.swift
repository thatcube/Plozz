#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

// MARK: - Landing

struct MusicLandingView: View {
    @State var viewModel: MusicLandingViewModel
    let controller: AudioPlaybackController
    let onSelectRoute: (MusicRoute) -> Void
    let onPlayTrack: (MusicTrack) -> Void
    var layout: MusicLandingLayout = .default

    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        ContentStateView(state: viewModel.state, emptyMessage: "No music found in your libraries.", onRetry: { Task { await viewModel.load() } }) { content in
            let firstSection = firstRenderedSection(content)
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    // The page is composed by iterating the data-driven layout, so
                    // reordering or hiding a section is a value change, not a rewrite.
                    ForEach(layout.visibleSections, id: \.self) { section in
                        sectionView(section, content: content, isFirst: section == firstSection)
                    }
                }
                .padding(.vertical, metrics.rowSpacing)
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
        }
        .task { if case .idle = viewModel.state { await viewModel.load() } }
        // Refresh the rails once a play has actually been recorded on the server,
        // so "Recently Played" reflects what was just listened to without needing
        // an app relaunch. `.task(id:)` coalesces a burst of finished tracks into a
        // single trailing refresh, and the initial token value (0) is skipped so
        // this never double-fetches on first appearance. The short delay gives the
        // server a moment to index the play before we re-query.
        .task(id: controller.recentPlayReportToken) {
            guard controller.recentPlayReportToken > 0 else { return }
            try? await Task.sleep(for: .seconds(1.5))
            await viewModel.load()
        }
    }

    /// The first section that will actually render given the loaded content, so
    /// we can hang the scrolling Now Playing card on its header (it lives on the
    /// trailing edge of the first existing section, not in a fixed overlay).
    private func firstRenderedSection(_ content: MusicLandingViewModel.Content) -> MusicLandingSection? {
        for section in layout.visibleSections {
            switch section {
            case .recentlyPlayed: if !content.recentlyPlayed.isEmpty { return section }
            case .browse: return section
            case .albums: if !content.albums.isEmpty { return section }
            case .artists: if !content.artists.isEmpty { return section }
            case .playlists: if !content.playlists.isEmpty { return section }
            }
        }
        return nil
    }

    /// The Now Playing card, wrapped for use as a header's trailing accessory.
    /// Self-hides when nothing is playing.
    private var nowPlayingTrailing: AnyView {
        AnyView(NowPlayingCard(controller: controller))
    }

    @ViewBuilder
    private func sectionView(_ section: MusicLandingSection, content: MusicLandingViewModel.Content, isFirst: Bool) -> some View {
        let trailing: AnyView? = isFirst ? nowPlayingTrailing : nil
        switch section {
        case .recentlyPlayed:
            if !content.recentlyPlayed.isEmpty {
                MusicRow(title: "Recently Played", trailing: trailing) {
                    ForEach(content.recentlyPlayed) { item in
                        switch item {
                        case let .album(album):
                            AlbumCard(album: album) { onSelectRoute(.album(album)) }
                        case let .track(track):
                            RecentTrackCard(track: track) { onPlayTrack(track) }
                        case let .playlist(playlist):
                            PlaylistCard(playlist: playlist) { onSelectRoute(.playlist(playlist)) }
                        }
                    }
                }
            }
        case .browse:
            entryTiles(trailing: trailing)
        case .albums:
            if !content.albums.isEmpty {
                MusicRow(title: "Albums", trailing: trailing) {
                    ForEach(content.albums) { album in
                        AlbumCard(album: album) { onSelectRoute(.album(album)) }
                    }
                }
            }
        case .artists:
            if !content.artists.isEmpty {
                MusicRow(title: "Artists", trailing: trailing) {
                    ForEach(content.artists) { artist in
                        ArtistCard(artist: artist) { onSelectRoute(.artist(artist)) }
                    }
                }
            }
        case .playlists:
            if !content.playlists.isEmpty {
                MusicRow(title: "Playlists", trailing: trailing) {
                    ForEach(content.playlists) { playlist in
                        PlaylistCard(playlist: playlist) { onSelectRoute(.playlist(playlist)) }
                    }
                }
            }
        }
    }

    /// The Browse row: text-only category buttons on the leading edge with the
    /// scrolling Now Playing card pinned to the trailing screen edge. Both insets
    /// are the standard `screenPadding`, so the card's right margin matches the
    /// buttons' left margin. No header — the labelled buttons are self-evident.
    private func entryTiles(trailing: AnyView?) -> some View {
        HStack(alignment: .center, spacing: metrics.cardSpacing) {
            BrowseButton(title: "Playlists") { onSelectRoute(.grid(.playlist)) }
            BrowseButton(title: "Albums") { onSelectRoute(.grid(.album)) }
            BrowseButton(title: "Artists") { onSelectRoute(.grid(.artist)) }
            BrowseButton(title: "Genres") { onSelectRoute(.grid(.genre)) }
            Spacer(minLength: metrics.cardSpacing)
            if let trailing { trailing }
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
    }
}

/// A text-only Browse category button. Its height matches the Now Playing card
/// (`NowPlayingCard.nominalHeight`) so the buttons and the card line up on one
/// row. Uses the app's shared media-card corner radius (`landscapeCardCornerRadius`,
/// the same radius the Recently Played cards use) and the shared glass-card focus
/// — the same treatment as every other media card — rather than a bespoke style.
private struct BrowseButton: View {
    let title: String
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzMetrics) private var metrics

    private var titleColor: Color {
        PlozzCardCaption.titleColor(isFocused: isFocused, reduceTransparency: reduceTransparency)
    }

    var body: some View {
        Text(title)
            .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
            .foregroundStyle(titleColor)
            .padding(.horizontal, PlozzTheme.Spacing.xLarge)
            .frame(height: NowPlayingCard.nominalHeight)
            .plozzGlassCard(cornerRadius: metrics.landscapeCardCornerRadius, isFocused: isFocused)
            .focusableCard(isFocused: $isFocused, cornerRadius: metrics.landscapeCardCornerRadius, action: action)
            .plozzCardRasterize(reduceTransparency: reduceTransparency)
            .shadow(color: .black.opacity(isFocused ? 0.36 : 0.15), radius: isFocused ? 20 : 8, y: isFocused ? 10 : 4)
            .scaleEffect(isFocused ? PlozzTheme.Metrics.mediumFocusedCardScale : 1)
            .zIndex(isFocused ? 2 : 0)
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// A horizontal rail with a title.
private struct MusicRow<Content: View>: View {
    let title: String
    /// Optional trailing accessory (used to hang the scrolling Now Playing card
    /// on the first section's header).
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
            HStack(spacing: 24) {
                Text(title).font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy so only on-screen cards build their Liquid Glass surface.
                // The eager HStack kept every card's glass effect live, so fast
                // focus moves recomputed every card's SDF and lagged navigation.
                // Matches the lazy rails used elsewhere (MediaRowView/HomeView).
                LazyHStack(alignment: .top, spacing: metrics.cardSpacing) {
                    content()
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                // Keep the rail clipping (no `scrollClipDisabled`) so the focus
                // engine holds the first/last card at its inset, and reserve room
                // *inside* the clip for the focused card's lift + shadow. The
                // negative outer padding restores the original vertical inset, so
                // the row's height is unchanged — only the clip grows.
                .padding(.vertical, metrics.railShadowClearance)
            }
            // Match the shared rails: a tight `railTopPadding`-based gap above the
            // cards (not the wide `railVerticalPadding` used below the row), so the
            // section header hugs the cards instead of floating far above them.
            .padding(.top, metrics.railTopClearanceOffset)
            .padding(.bottom, metrics.railBottomClearanceOffset)
        }
    }
}

/// A shared top-level page header: a big title on the left and the scrolling
/// Now Playing card pinned to the far right. Used by the grid pages (Albums,
/// Artists, Playlists, Genres) so the now-playing control scrolls with the page
/// instead of floating in a fixed overlay. The card self-hides when nothing is
/// playing.
struct MusicPageHeader: View {
    let title: String
    var titleFont: Font = .system(size: 48, weight: .bold)
    var controller: AudioPlaybackController

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(title).font(titleFont)
            Spacer(minLength: 24)
            NowPlayingCard(controller: controller)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
    }
}

// MARK: - Grid

struct MusicGridView: View {
    @State var viewModel: MusicGridViewModel
    let controller: AudioPlaybackController
    let onSelectRoute: (MusicRoute) -> Void

    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        // Density-scaled adaptive columns: a wider minimum at higher density gives
        // fewer, bigger tiles (and matches the larger music cards), so the music
        // grids respond to the UI-density setting like the movie/show wall.
        let columns = [GridItem(.adaptive(minimum: (280 * metrics.scale).rounded()), spacing: metrics.gridSpacing)]
        return ContentStateView(state: viewModel.state, emptyMessage: emptyMessage, onRetry: { Task { await viewModel.loadMore() } }) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    MusicPageHeader(title: title, controller: controller)
                        .padding(.top, metrics.rowSpacing)

                    LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
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
    let controller: AudioPlaybackController
    let onSelectAlbum: (MusicAlbum) -> Void

    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: (280 * metrics.scale).rounded()), spacing: metrics.gridSpacing)]
        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                HStack(alignment: .top, spacing: 32) {
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
                    // Now Playing card scrolls with the page, pinned top-right.
                    NowPlayingCard(controller: controller)
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                // Make the hero its own focus section so pressing Up from anywhere
                // in the albums grid below reliably lands on the Now Playing card,
                // even when it's far to the right (off the album's vertical axis).
                .focusSection()

                Text("Albums").font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
                    .padding(.horizontal, PlozzTheme.Metrics.screenPadding)

                LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
                    ForEach(viewModel.albums) { album in
                        AlbumCard(album: album) { onSelectAlbum(album) }
                    }
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                // Own focus section so pressing Down from the Now Playing card
                // (pinned top-right of the hero) drops back into the grid, even
                // though no album sits directly beneath it.
                .focusSection()
            }
            .padding(.vertical, metrics.rowSpacing)
        }
        .scrollClipDisabled()
        .task { await viewModel.load() }
    }
}

// MARK: - Album detail

struct AlbumDetailView: View {
    @State var viewModel: AlbumDetailViewModel
    let controller: AudioPlaybackController

    /// Lands initial focus on the Play button rather than the top of the track
    /// list. Set once tracks load (Play is disabled until then).
    @FocusState private var playFocused: Bool

    var body: some View {
        MusicDetailLayout(
            tracks: viewModel.tracks,
            artworkFallback: viewModel.album.artworkURL,
            nowPlayingTrackID: controller.currentTrack?.id,
            isPlaying: controller.isPlaying,
            hasNowPlaying: controller.hasActivePlayback,
            onPlayTrack: { play(from: $0) }
        ) {
            infoColumn
        }
        .defaultFocus($playFocused, true)
        .task {
            await viewModel.load()
            // Play is disabled until tracks exist, so a declarative default alone
            // can't land on it at appear. Set focus explicitly once loaded, after
            // a short runloop hop so the focus engine sees the now-enabled button.
            try? await Task.sleep(for: .milliseconds(50))
            if !viewModel.tracks.isEmpty { playFocused = true }
        }
    }

    private let columnWidth: CGFloat = 480

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
                .frame(width: columnWidth, height: columnWidth)
            Text(viewModel.album.title).font(.system(size: 40, weight: .bold)).lineLimit(3)
            Text(viewModel.album.subtitleLine).font(.body).foregroundStyle(.secondary).lineLimit(2)
            if let count = viewModel.album.trackCount {
                Text("\(count) tracks · \(MusicFormat.duration(viewModel.album.totalDuration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            PlayShuffleButtons(
                isEmpty: viewModel.tracks.isEmpty,
                onPlay: { play(from: nil) },
                onShuffle: { shuffle() },
                fillWidth: true,
                playFocus: $playFocused
            )
            .frame(width: columnWidth)
            .padding(.top, 8)

            // The Now Playing card sits under the Play/Shuffle buttons. It shows
            // whenever something is playing (including a track from this very
            // album) so the user always has a quick way back to the player.
            NowPlayingCard(controller: controller, fillWidth: true)
                .frame(width: columnWidth)
                .padding(.top, 12)
        }
    }

    private func play(from track: MusicTrack?) {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        let start = track.flatMap { t in viewModel.tracks.firstIndex(where: { $0.id == t.id }) } ?? 0
        controller.play(
            tracks: viewModel.tracks,
            startIndex: start,
            resolveStreamURL: streamURLResolver(for: provider),
            resolveLyrics: lyricsResolver(for: provider),
            refreshLyrics: lyricsRefresher(for: provider),
            reportPlayback: playbackReporter(for: provider)
        )
    }

    private func shuffle() {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        controller.playShuffled(
            tracks: viewModel.tracks,
            resolveStreamURL: streamURLResolver(for: provider),
            resolveLyrics: lyricsResolver(for: provider),
            refreshLyrics: lyricsRefresher(for: provider),
            reportPlayback: playbackReporter(for: provider)
        )
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    @State var viewModel: PlaylistDetailViewModel
    let controller: AudioPlaybackController

    /// Lands initial focus on the Play button rather than the top of the track
    /// list. Set once tracks load (Play is disabled until then).
    @FocusState private var playFocused: Bool

    var body: some View {
        MusicDetailLayout(
            tracks: viewModel.tracks,
            artworkFallback: viewModel.playlist.artworkURL,
            showArtist: true,
            showArtwork: true,
            nowPlayingTrackID: controller.currentTrack?.id,
            isPlaying: controller.isPlaying,
            hasNowPlaying: controller.hasActivePlayback,
            onPlayTrack: { play(from: $0) }
        ) {
            infoColumn
        }
        .defaultFocus($playFocused, true)
        .task {
            await viewModel.load()
            // Play is disabled until tracks exist, so a declarative default alone
            // can't land on it at appear. Set focus explicitly once loaded, after
            // a short runloop hop so the focus engine sees the now-enabled button.
            try? await Task.sleep(for: .milliseconds(50))
            if !viewModel.tracks.isEmpty { playFocused = true }
        }
    }

    private let columnWidth: CGFloat = 480

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            MusicArtworkImage(url: viewModel.playlist.artworkURL, systemPlaceholder: "music.note.list")
                .frame(width: columnWidth, height: columnWidth)
            Text(viewModel.playlist.title).font(.system(size: 40, weight: .bold)).lineLimit(3)
            Text("\(viewModel.tracks.count) tracks").font(.body).foregroundStyle(.secondary)
            PlayShuffleButtons(
                isEmpty: viewModel.tracks.isEmpty,
                onPlay: { play(from: nil) },
                onShuffle: { shuffle() },
                fillWidth: true,
                playFocus: $playFocused
            )
            .frame(width: columnWidth)
            .padding(.top, 8)

            // The Now Playing card sits under the Play/Shuffle buttons. It shows
            // whenever something is playing (including a track from this very
            // playlist) so the user always has a quick way back to the player.
            NowPlayingCard(controller: controller, fillWidth: true)
                .frame(width: columnWidth)
                .padding(.top, 12)
        }
    }

    private func play(from track: MusicTrack?) {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        let start = track.flatMap { t in viewModel.tracks.firstIndex(where: { $0.id == t.id }) } ?? 0
        controller.play(
            tracks: viewModel.tracks,
            startIndex: start,
            resolveStreamURL: streamURLResolver(for: provider),
            resolveLyrics: lyricsResolver(for: provider),
            refreshLyrics: lyricsRefresher(for: provider),
            reportPlayback: playbackReporter(for: provider)
        )
    }

    private func shuffle() {
        guard let provider = viewModel.provider, !viewModel.tracks.isEmpty else { return }
        controller.playShuffled(
            tracks: viewModel.tracks,
            resolveStreamURL: streamURLResolver(for: provider),
            resolveLyrics: lyricsResolver(for: provider),
            refreshLyrics: lyricsRefresher(for: provider),
            reportPlayback: playbackReporter(for: provider)
        )
    }
}

// MARK: - Shared subviews

struct PlayShuffleButtons: View {
    let isEmpty: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void
    /// When true the row spans its container with Play stretching to fill the
    /// leftover width and Shuffle keeping its natural size.
    var fillWidth: Bool = false
    /// When provided, the Play button binds this focus state so the enclosing
    /// detail view can land initial focus on Play (via `.defaultFocus` plus an
    /// explicit set once tracks load) instead of the top of the track list.
    var playFocus: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 20) {
            playButton
            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "shuffle").padding(.horizontal, 12)
            }
            .buttonStyle(.bordered)
            .disabled(isEmpty)
        }
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder
    private var playButton: some View {
        let button = Button(action: onPlay) {
            Label("Play", systemImage: "play.fill")
                .padding(.horizontal, 12)
                .frame(maxWidth: fillWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isEmpty)

        if let playFocus {
            button.focused(playFocus, equals: true)
        } else {
            button
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
    var showArtwork: Bool = false
    var nowPlayingTrackID: String? = nil
    var isPlaying: Bool = false
    /// Whether the Now Playing card is currently shown in the info column. When
    /// it isn't, the (shorter) column is nudged down so it reads as more
    /// vertically centred, while both column tops stay aligned.
    var hasNowPlaying: Bool = false
    let onPlayTrack: (MusicTrack) -> Void
    @ViewBuilder var info: InfoColumn

    // Pull the whole detail up under tvOS's reserved top safe-area inset so the
    // artwork + track list don't sit too low. With the Now Playing card present
    // this yields even top/bottom padding; without it the column is ~one card
    // shorter, so add roughly half a card's height back to re-centre it.
    private var topPadding: CGFloat {
        let base = PlozzTheme.Metrics.screenPadding - 80
        return hasNowPlaying ? base : base + 54
    }

    var body: some View {
        GeometryReader { geo in
            // Give the album/playlist info column ~a third of the screen so the
            // Play and Shuffle buttons fit comfortably side by side.
            let infoWidth = max(480, geo.size.width * 0.33)
            let bottomInset = PlozzTheme.Metrics.screenPadding
            // Side gutters inside the scroll view. The leading one gives the
            // focus scale + shadow room to grow without being clipped by the
            // scroll view's frame. The trailing one does the same AND leaves a
            // clear gap for the system scroll indicator so it sits well to the
            // right of the track durations. The scroll area is widened to match
            // (tighter column spacing on the left, smaller trailing page padding
            // on the right) so the left text position is preserved and the rows
            // stay close to their current width.
            let leftGutter: CGFloat = 60
            let rightGutter: CGFloat = 80
            let trailingPad: CGFloat = 24
            HStack(alignment: .top, spacing: 56 - leftGutter) {
                info
                    .frame(width: infoWidth, alignment: .leading)
                    // Position the info column with the shared top offset; the
                    // track list uses the same value for its top content margin
                    // so both tops stay aligned. The focus section spans the full
                    // height so Left from any track row still reaches the
                    // transport controls.
                    .padding(.top, topPadding)
                    .padding(.bottom, bottomInset)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .focusSection()
                ScrollView {
                    TrackListView(
                        tracks: tracks,
                        artworkFallback: artworkFallback,
                        showArtist: showArtist,
                        showArtwork: showArtwork,
                        nowPlayingTrackID: nowPlayingTrackID,
                        isPlaying: isPlaying,
                        onPlayTrack: onPlayTrack
                    )
                }
                // The scroll view fills the full page height so rows travel all
                // the way to the page's top and bottom edges instead of vanishing
                // at an inset boundary. Content margins keep the first row aligned
                // with the artwork (same offset as the info column) and leave a
                // little breathing room at the bottom.
                .frame(maxHeight: .infinity)
                .contentMargins(.top, topPadding, for: .scrollContent)
                .contentMargins(.bottom, bottomInset + 24, for: .scrollContent)
                // Inset the rows from the scroll view's side edges so the focus
                // scale + shadow have room to grow without being clipped, and the
                // scroll indicator lands in the right-hand gutter, clear of the
                // durations. Default vertical clipping is kept so rows still
                // scroll cleanly to the page's top and bottom edges.
                .contentMargins(.leading, leftGutter, for: .scrollContent)
                .contentMargins(.trailing, rightGutter, for: .scrollContent)
                // Track list is its own focus section so Right from the info
                // column reliably enters the list regardless of row alignment.
                .focusSection()
            }
            .padding(.leading, PlozzTheme.Metrics.screenPadding)
            .padding(.trailing, trailingPad)
        }
    }
}

struct TrackListView: View {
    let tracks: [MusicTrack]
    var artworkFallback: URL?
    var showArtist: Bool = false
    /// Whether to show each track's own album artwork as a leading thumbnail.
    /// Used for playlists (whose tracks span many albums); albums keep the
    /// numbered list since every row shares one cover.
    var showArtwork: Bool = false
    /// The id of the track currently loaded in the player (if any), so the row
    /// shows an animated equalizer instead of its track number.
    var nowPlayingTrackID: String? = nil
    /// Whether the player is actively playing (vs paused) — drives whether the
    /// equalizer bars animate or sit still.
    var isPlaying: Bool = false
    let onPlayTrack: (MusicTrack) -> Void

    var body: some View {
        // LazyVStack so only the on-screen rows are built — playlists can hold
        // thousands of tracks, and an eager VStack materialised every row at once
        // (8000+ → out-of-memory crash).
        LazyVStack(spacing: 4) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                let isCurrent = track.id == nowPlayingTrackID
                Button { onPlayTrack(track) } label: {
                    HStack(spacing: 20) {
                        leadingAccessory(track: track, index: index, isCurrent: isCurrent)
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
                .onAppear { prefetchArtwork(around: index) }
            }
        }
    }

    /// Warms the decoded-image cache for a window of rows just *below* the one
    /// that appeared, so a normal downward scroll finds each playlist thumbnail
    /// already decoded and it renders instantly instead of fading in. Bounded
    /// lookahead + the cache's background-warm limiter keep this cheap even on an
    /// 8000-track playlist. No-op for albums (numbered list, no per-row art).
    private func prefetchArtwork(around index: Int) {
        #if canImport(UIKit)
        guard showArtwork, !tracks.isEmpty else { return }
        let lookahead = 16
        let end = min(index + lookahead, tracks.count - 1)
        guard end > index else { return }
        for i in (index + 1)...end {
            if let url = tracks[i].artworkURL ?? artworkFallback {
                ArtworkImageCache.shared.prefetch(url, variant: .musicThumbnail)
            }
        }
        #endif
    }

    /// The leading column of a track row. Playlists show the track's own album
    /// artwork (with a now-playing equalizer overlaid when it's the current
    /// track); albums keep the numbered list, swapping the number for an
    /// equalizer while playing.
    @ViewBuilder
    private func leadingAccessory(track: MusicTrack, index: Int, isCurrent: Bool) -> some View {
        if showArtwork {
            MusicArtworkImage(
                url: track.artworkURL ?? artworkFallback,
                systemPlaceholder: "music.note",
                cornerRadius: 8,
                variant: .musicThumbnail
            )
            .frame(width: 72, height: 72)
            .overlay {
                if isCurrent {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.black.opacity(0.45))
                        NowPlayingEqualizer(isAnimating: isPlaying)
                    }
                }
            }
        } else {
            Group {
                if isCurrent {
                    NowPlayingEqualizer(isAnimating: isPlaying)
                } else {
                    Text(track.trackNumber.map(String.init) ?? "\(index + 1)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(width: 56, alignment: .trailing)
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
    /// Optional bar color. Defaults to the app accent; the Now Playing card
    /// passes the inverted focus foreground so the bars stay legible on the
    /// contrast-flipped focused card.
    var tint: Color? = nil
    /// Multiplier on the intrinsic bar/frame dimensions. Defaults to 1 so the
    /// track-list and mini-player instances keep their established size; the
    /// Now Playing title cue passes a larger value to read at a distance.
    var scale: CGFloat = 1
    private let barCount = 4

    var body: some View {
        // No `minimumInterval` so the timeline updates at the display's native
        // refresh rate (60fps on Apple TV). A throttled interval here made the
        // sine-driven bars visibly step/stutter.
        TimelineView(.animation(paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 3 * scale) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(tint ?? Color.accentColor)
                        .frame(width: 4 * scale, height: height(bar: i, at: t))
                }
            }
            .frame(height: 24 * scale, alignment: .bottom)
        }
    }

    private func height(bar i: Int, at t: TimeInterval) -> CGFloat {
        guard isAnimating else { return 9 * scale }
        // Sum of a few incommensurate sine waves per bar: unlike a single sine
        // (a repeating wave) it never settles into a visible period, and unlike
        // value noise it moves continuously with momentum — no start/stop stutter.
        let p = Double(i) * 1.7            // per-bar phase offset (decorrelates bars)
        let f = 1.0 + Double(i) * 0.04     // slight per-bar detune so they never sync
        let s = sin(t * 6.4 * f + p)                       // primary bounce (a touch faster)
              + 0.4  * sin(t * 3.4 * f + p * 1.3 + 1.1)    // slower swell (tamed)
              + 0.26 * sin(t * 9.0 * f + p * 0.7 + 2.2)    // faster shimmer (tamed)
        let v = min(max(s / 3.32 + 0.5, 0), 1) // 0...1
        return (4 + CGFloat(v) * 18) * scale  // (4...22) * scale
    }
}
#endif
