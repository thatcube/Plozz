#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

/// Navigation routes inside the Music tab's stack.
enum MusicRoute: Hashable {
    case grid(MusicItemKind)
    case artist(MusicArtist)
    case album(MusicAlbum)
    case playlist(MusicPlaylist)
}

/// The Music tab: a `NavigationStack` over the landing screen, with a persistent
/// mini-player pinned to the bottom that is visible **only** while audio is
/// loaded and never auto-grabs focus. Tapping it opens the full Now Playing
/// screen.
///
/// Injected with the app-scoped `AudioPlaybackController` so the mini-player and
/// Now Playing observe the same engine that keeps playing in the background.
public struct MusicTabView: View {
    private let context: MusicContext
    private let controller: AudioPlaybackController

    @State private var path = NavigationPath()
    @State private var showNowPlaying = false

    public init(accounts: [ResolvedAccount], controller: AudioPlaybackController) {
        self.context = MusicContext(accounts: accounts)
        self.controller = controller
    }

    public var body: some View {
        NavigationStack(path: $path) {
            MusicLandingView(
                viewModel: MusicLandingViewModel(context: context),
                onSelectRoute: { path.append($0) }
            )
            .navigationDestination(for: MusicRoute.self) { route in
                destination(for: route)
            }
        }
        // A single floating Now Playing pill over the whole Music tab, pinned
        // top-trailing. It lives outside the content's vertical focus path, so
        // pressing *down* through a track list never fights the focus engine, and
        // it persists across pushes without a per-screen toolbar.
        .overlay(alignment: .topTrailing) {
            if !showNowPlaying {
                NowPlayingPill(controller: controller) { showNowPlaying = true }
                    .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                    .padding(.top, 24)
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(controller: controller)
        }
        // Starting a song jumps straight into the full-screen player, like
        // Apple Music. The pill remains for re-opening it after dismissal.
        .onChange(of: controller.playbackStartToken) { _, _ in
            showNowPlaying = true
        }
    }

    @ViewBuilder
    private func destination(for route: MusicRoute) -> some View {
        // Hide the top tab bar once the user drills one level in (grid, artist,
        // album, playlist, etc.) so detail screens get the full height; it
        // reappears automatically when they pop back to the landing screen.
        Group {
            switch route {
            case let .grid(kind):
                MusicGridView(
                    viewModel: MusicGridViewModel(context: context, kind: kind),
                    controller: controller,
                    onSelectRoute: { path.append($0) }
                )
            case let .artist(artist):
                ArtistDetailView(
                    viewModel: ArtistDetailViewModel(artist: artist, context: context),
                    onSelectAlbum: { path.append(MusicRoute.album($0)) }
                )
            case let .album(album):
                AlbumDetailView(
                    viewModel: AlbumDetailViewModel(album: album, context: context),
                    controller: controller
                )
            case let .playlist(playlist):
                PlaylistDetailView(
                    viewModel: PlaylistDetailViewModel(playlist: playlist, context: context),
                    controller: controller
                )
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - Playback starting helper

/// Builds a stream-URL resolver bound to a music provider, so the engine can
/// advance through a queue without coupling to any concrete provider.
@MainActor
func streamURLResolver(for provider: any MusicProvider) -> AudioPlaybackController.StreamURLResolver {
    { track in
        guard let info = try? await provider.audioPlaybackInfo(for: track.id, queueContext: nil) else {
            return nil
        }
        return AudioPlaybackController.ResolvedStream(url: info.streamURL, quality: info.quality)
    }
}
#endif
