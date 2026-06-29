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
            resolveLyrics: lyricsResolver(for: provider),
            refreshLyrics: lyricsRefresher(for: provider)
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
            return AudioPlaybackController.LyricsResolution(
                lyrics: cached,
                isRememberedNegative: cached == nil
            )
        }
        // L2: on-disk cache from previous sessions. A negative hit here is the
        // big saving for instrumental tracks — once we've ever asked and found
        // nothing, we skip the network round-trip and stay silent on the UI.
        // `AudioPlaybackController` re-checks remembered negatives in the
        // background (debounced) so a song that *later* gains an LRCLIB upload
        // still surfaces without the user doing anything.
        if let cached = await LyricsDiskCache.shared.cached(track.id) {
            await LyricsMemoCache.shared.set(cached, for: track.id)
            return AudioPlaybackController.LyricsResolution(
                lyrics: cached,
                isRememberedNegative: cached == nil
            )
        }
        // L3: title heuristic for explicitly-marked instrumental/karaoke
        // tracks. We still persist this through the cache layers so we don't
        // re-evaluate it on every play.
        if isExplicitlyInstrumental(title: track.title) {
            await LyricsMemoCache.shared.set(nil, for: track.id)
            await LyricsDiskCache.shared.store(nil, for: track.id)
            return AudioPlaybackController.LyricsResolution(
                lyrics: nil,
                isRememberedNegative: true
            )
        }
        let resolution = await resolveSyncedLyrics(for: track, provider: provider)
        // Only persist this result when we're confident it reflects a real
        // verdict from a server, not a transport failure (offline / DNS / TLS).
        // Otherwise an Apple TV that briefly lost wifi would permanently
        // remember "no lyrics" for every song played during the outage.
        // Still memoise within this session so a quick track ↔ track flick
        // doesn't re-issue the same failing request every few seconds.
        await LyricsMemoCache.shared.set(resolution.lyrics, for: track.id)
        if resolution.isAuthoritative {
            await LyricsDiskCache.shared.store(resolution.lyrics, for: track.id)
        }
        // First-time resolution: not a remembered negative, so the UI is
        // allowed to show "No lyrics found" if `lyrics` is nil. This is the
        // only path that lets that message ever appear.
        return AudioPlaybackController.LyricsResolution(
            lyrics: resolution.lyrics,
            isRememberedNegative: false
        )
    }
}

/// Background re-check for a track whose visible state is `.silent`. Honours
/// a per-track debounce (`refreshDebounce`) so playing the same instrumental
/// repeatedly costs at most one network round-trip per debounce window, and
/// returns lyrics only when the fresh lookup actually found something the
/// cache didn't have — never re-flashes "No lyrics found".
///
/// On a successful find, updates both cache layers so future plays resolve
/// from L1/L2 with the new lyrics, no extra refresh needed. On a still-empty
/// result, `touch`es the disk entry so the debounce clock resets and we
/// don't re-check this track again until the next window.
@MainActor
func lyricsRefresher(for provider: any MusicProvider) -> AudioPlaybackController.LyricsRefresher {
    { track in
        // Skip if we recently re-checked. 7 days is long enough that an
        // instrumental track on heavy rotation costs effectively zero network
        // traffic, short enough that a newly-uploaded LRCLIB record surfaces
        // within a week of any future play of the song.
        let refreshDebounce: TimeInterval = 60 * 60 * 24 * 7
        if let age = await LyricsDiskCache.shared.entryAge(track.id), age < refreshDebounce {
            return nil
        }
        let resolution = await resolveSyncedLyrics(for: track, provider: provider)
        // Don't change anything if the device is offline — leave the existing
        // entry intact and let a future play try again. We only "consume" the
        // debounce window on an authoritative response.
        guard resolution.isAuthoritative else { return nil }
        if let lyrics = resolution.lyrics, !lyrics.isEmpty, lyrics.isSynced {
            // Found new lyrics — promote into both caches so the next play
            // resolves them instantly from L2 with no refresh needed.
            await LyricsMemoCache.shared.set(lyrics, for: track.id)
            await LyricsDiskCache.shared.store(lyrics, for: track.id)
            return lyrics
        } else {
            // Still nothing — reset the debounce clock without changing the
            // stored answer so we don't re-check again for another week.
            await LyricsDiskCache.shared.touch(track.id)
            return nil
        }
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
///
/// The `isAuthoritative` flag reports whether at least one source actually
/// reached a server (positive *or* negative). When both sources fail at the
/// transport layer (offline, DNS, TLS), we return `(nil, isAuthoritative:
/// false)` so callers can avoid burning that mistaken "no lyrics" into the
/// persistent cache.
private func resolveSyncedLyrics(
    for track: MusicTrack,
    provider: any MusicProvider
) async -> (lyrics: Lyrics?, isAuthoritative: Bool) {
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
    struct Outcome { let source: Source; let lyrics: Lyrics?; let reachable: Bool }

    return await withTaskGroup(of: Outcome.self) { group in
        group.addTask {
            // Treat a URLError thrown by the server as a transport failure
            // (offline / DNS / TLS / timeout) rather than a real "no lyrics"
            // answer. Any other error (auth, decode, server bug) we treat as
            // a real verdict — better than re-querying forever on a broken
            // backend that's still online enough to return 5xx.
            do {
                let lyrics = try await provider.lyrics(for: track.id)
                return Outcome(source: .server, lyrics: lyrics, reachable: true)
            } catch is URLError {
                return Outcome(source: .server, lyrics: nil, reachable: false)
            } catch {
                return Outcome(source: .server, lyrics: nil, reachable: true)
            }
        }
        if lrclibAvailable, let artist {
            group.addTask {
                let result = await LRCLIBLyricsProvider().lyricsWithStatus(
                    title: track.title,
                    artist: artist,
                    album: track.albumTitle,
                    duration: track.duration
                )
                return Outcome(source: .lrclib, lyrics: result.lyrics, reachable: result.reachable)
            }
        }

        var pendingLRCLIB: Lyrics?
        var sawServer = false
        var anyReachable = false
        for await outcome in group {
            if outcome.reachable { anyReachable = true }
            let synced = (outcome.lyrics?.isSynced == true && outcome.lyrics?.isEmpty == false)
                ? outcome.lyrics
                : nil
            switch outcome.source {
            case .server:
                sawServer = true
                if let synced {
                    group.cancelAll()
                    return (synced, true)
                }
                // Server said "no synced lyrics" — if LRCLIB already finished
                // with a synced copy, use it; otherwise keep waiting on LRCLIB.
                if let pendingLRCLIB {
                    group.cancelAll()
                    return (pendingLRCLIB, true)
                }
            case .lrclib:
                if let synced {
                    // Wait for the server only if it's still pending, to give
                    // its (preferred) attribution a chance to land first.
                    if sawServer {
                        group.cancelAll()
                        return (synced, true)
                    }
                    pendingLRCLIB = synced
                } else if sawServer {
                    // Both sources finished without synced lyrics.
                    return (nil, anyReachable)
                }
            }
        }
        return (pendingLRCLIB, anyReachable)
    }
}
#endif
