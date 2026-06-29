#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit
import Inject

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

    @ObserveInjection var inject

    public var body: some View {
        NavigationStack(path: $path) {
            MusicLandingView(
                viewModel: MusicLandingViewModel(context: context, cache: .shared),
                controller: controller,
                onSelectRoute: { path.append($0) },
                onPlayTrack: { playTrack($0) },
                layout: layoutModel.layout
            )
            .navigationDestination(for: MusicRoute.self) { route in
                destination(for: route)
            }
        }
        // The Now Playing control is no longer a fixed overlay — it lives inside
        // each page's header and scrolls with the content. We plumb the "open the
        // full player" action down via the environment so any header's
        // `NowPlayingCard` can trigger it without threading a closure through
        // every screen.
        .environment(\.openNowPlaying) { showNowPlaying = true }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(controller: controller, appTheme: appTheme, musicPlayer: musicPlayer)
        }
        // Starting a song jumps straight into the full-screen player, like
        // Apple Music. The card remains for re-opening it after dismissal.
        .onChange(of: controller.playbackStartToken) { _, _ in
            showNowPlaying = true
        }
        .enableInjection()
    }

    /// Plays a single recently-played song from the landing rail. Resolves the
    /// owning provider from the track's source account so the same engine (stream
    /// + lyrics resolvers) used by album/playlist playback drives it, then starts
    /// a one-track queue — which also flips into the full-screen player via the
    /// playbackStartToken observer above.
    private func playTrack(_ track: MusicTrack) {
        guard let provider = context.provider(for: track.sourceAccountID) else { return }
        controller.play(
            tracks: [track],
            startIndex: 0,
            resolveStreamURL: streamURLResolver(for: provider),
            resolveLyrics: lyricsResolver(for: provider)
        )
    }

    @ViewBuilder
    private func destination(for route: MusicRoute) -> some View {        // Hide the top tab bar once the user drills one level in (grid, artist,
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
                    controller: controller,
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
/// Races the user's server and the keyless LRCLIB fallback **in parallel** for
/// the first synced result. Three layers of caching collapse the visible wait
/// to ~instant on a repeat play of the same track:
///
///  1. `LyricsMemoCache` (in-memory, this session) — covers track ↔ track
///     hand-offs and the next-track prefetch.
///  2. `LyricsDiskCache` (persistent, across launches) — covers re-playing a
///     track you've played any time in the last month, including remembering
///     that an instrumental piece like Escala's *Palladio* has no lyrics so
///     we never search for it again.
///  3. Title heuristic (`isExplicitlyInstrumental`) — short-circuits tracks
///     whose own title says they're instrumental/karaoke without touching the
///     network at all.
///
/// Each result carries its own source tag (Jellyfin/Plex/LRCLIB) for the
/// attribution badge.
func lyricsResolver(for provider: any MusicProvider) -> AudioPlaybackController.LyricsResolver {
    { track in
        // L1: in-memory memo for this session.
        if let cached = await LyricsMemoCache.shared.value(for: track.id) {
            return cached
        }
        // L2: on-disk cache from previous sessions. A negative hit here is the
        // big saving for instrumental tracks — once we've ever asked and found
        // nothing, we skip every network round-trip on future plays.
        if let cached = await LyricsDiskCache.shared.cached(track.id) {
            await LyricsMemoCache.shared.set(cached, for: track.id)
            return cached
        }
        // L3: title heuristic for explicitly-marked instrumental/karaoke
        // tracks. We still persist this through the cache layers so we don't
        // re-evaluate it on every play.
        if isExplicitlyInstrumental(title: track.title) {
            await LyricsMemoCache.shared.set(nil, for: track.id)
            await LyricsDiskCache.shared.store(nil, for: track.id)
            return nil
        }
        let resolved = await resolveSyncedLyrics(for: track, provider: provider)
        await LyricsMemoCache.shared.set(resolved, for: track.id)
        await LyricsDiskCache.shared.store(resolved, for: track.id)
        return resolved
    }
}

/// Fans the server lookup and the LRCLIB fallback out concurrently and returns
/// the **first synced** result from either source. Previously this awaited the
/// server before even peeking at LRCLIB, so a slow server pinned the visible
/// wait even when LRCLIB would have answered in 200ms. The server is given a
/// short head-start window so its result (which carries the user's own library
/// attribution) wins all ties — if it hasn't produced synced lyrics by the time
/// LRCLIB has, we take the LRCLIB result. Plain (unsynced) results never win,
/// since the TV UI can't scroll them.
private func resolveSyncedLyrics(
    for track: MusicTrack,
    provider: any MusicProvider
) async -> Lyrics? {
    // Read the global lyrics-enabled toggle defensively so the on-by-default
    // applies when the key was never written. Skips LRCLIB entirely when the
    // user has turned lyrics off, so we don't send their track title/artist
    // to a third party for a panel they've hidden.
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
    let artist = track.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let lrclibAvailable = lyricsEnabled && artist.map { !$0.isEmpty } ?? false

    enum Source { case server, lrclib }
    struct Outcome { let source: Source; let lyrics: Lyrics? }

    return await withTaskGroup(of: Outcome.self) { group in
        group.addTask {
            let lyrics = try? await provider.lyrics(for: track.id)
            return Outcome(source: .server, lyrics: lyrics)
        }
        if lrclibAvailable, let artist {
            group.addTask {
                let lyrics = await LRCLIBLyricsProvider().lyrics(
                    title: track.title,
                    artist: artist,
                    album: track.albumTitle,
                    duration: track.duration
                )
                return Outcome(source: .lrclib, lyrics: lyrics)
            }
        }

        var pendingLRCLIB: Lyrics?
        var sawServer = false
        for await outcome in group {
            let synced = (outcome.lyrics?.isSynced == true && outcome.lyrics?.isEmpty == false)
                ? outcome.lyrics
                : nil
            switch outcome.source {
            case .server:
                sawServer = true
                if let synced {
                    group.cancelAll()
                    return synced
                }
                // Server said "no synced lyrics" — if LRCLIB already finished
                // with a synced copy, use it; otherwise keep waiting on LRCLIB.
                if let pendingLRCLIB {
                    group.cancelAll()
                    return pendingLRCLIB
                }
            case .lrclib:
                if let synced {
                    // Wait for the server only if it's still pending, to give
                    // its (preferred) attribution a chance to land first.
                    if sawServer {
                        group.cancelAll()
                        return synced
                    }
                    pendingLRCLIB = synced
                } else if sawServer {
                    // Both sources finished without synced lyrics.
                    return nil
                }
            }
        }
        return pendingLRCLIB
    }
}
#endif
