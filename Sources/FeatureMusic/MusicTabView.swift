#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit

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
    private let appTheme: AppTheme
    private let musicPlayer: MusicPlayerSettingsModel

    @State private var path = NavigationPath()
    @State private var showNowPlaying = false
    @State private var layoutModel = MusicLandingLayoutModel()

    public init(accounts: [ResolvedAccount], visibleLibraryIDs: [String: [String]] = [:], controller: AudioPlaybackController, appTheme: AppTheme = .system, musicPlayer: MusicPlayerSettingsModel) {
        self.context = MusicContext(
            accounts: accounts,
            visibleLibraryIDs: visibleLibraryIDs.isEmpty ? nil : visibleLibraryIDs
        )
        self.controller = controller
        self.appTheme = appTheme
        self.musicPlayer = musicPlayer
    }

    public var body: some View {
        NavigationStack(path: $path) {
            MusicLandingView(
                viewModel: MusicLandingViewModel(context: context, cache: .shared),
                onSelectRoute: { path.append($0) },
                layout: layoutModel.layout
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
            NowPlayingView(controller: controller, appTheme: appTheme, musicPlayer: musicPlayer)
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

/// Builds a lyrics resolver bound to a music provider, mirroring
/// `streamURLResolver`, so the Now Playing lyrics panel works for whichever
/// backend owns the track.
@MainActor
/// Resolves a track's lyrics, returning **only a synced (scrollable/karaoke)
/// version**. On a TV there's no way to manually scroll plain lyrics, so an
/// unsynced result is treated as "no lyrics": we just show the centered song.
/// Tries the user's server first; if it has no synced lyrics, consults the
/// keyless LRCLIB fallback and uses that only when it's synced. Each result
/// carries its own source tag (Jellyfin/Plex/LRCLIB) for the attribution badge.
func lyricsResolver(for provider: any MusicProvider) -> AudioPlaybackController.LyricsResolver {
    { track in
        let serverLyrics = try? await provider.lyrics(for: track.id)
        if let serverLyrics, !serverLyrics.isEmpty, serverLyrics.isSynced {
            return serverLyrics
        }

        // Server had no synced lyrics — try LRCLIB for a synced copy, but only
        // when the user hasn't turned lyrics off. Don't send a opted-out user's
        // track title/artist to a third party (lrclib.net) just to populate a
        // panel they've hidden. Read defensively so the on-by-default applies
        // when the key was never written.
        //
        // NOTE: this reads the *global* lyrics-enabled key, which is correct
        // today because the toggle is global. If the "show lyrics" toggle is
        // ever made per-profile (it lives as @AppStorage in NowPlayingView while
        // appearance/showTrackDetails went per-profile in MusicPlayerSettingsStore),
        // this read MUST become profile-namespace-scoped (SettingsKey.scoped) at
        // the same time — otherwise the resolver reads the global key while the UI
        // writes a scoped one and this gating silently desyncs.
        let lyricsEnabled = UserDefaults.standard.object(forKey: MusicLyricsPreference.storageKey) as? Bool
            ?? MusicLyricsPreference.defaultEnabled
        if lyricsEnabled,
           let artist = track.artistName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !artist.isEmpty {
            let lrclibLyrics = await LRCLIBLyricsProvider().lyrics(
                title: track.title,
                artist: artist,
                album: track.albumTitle,
                duration: track.duration
            )
            if let lrclibLyrics, lrclibLyrics.isSynced {
                return lrclibLyrics
            }
        }

        // Nothing synced anywhere: report no lyrics so the player stays centered.
        return nil
    }
}
#endif
