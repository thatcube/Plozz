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

/// Builds the cache key for a track's lyrics. Scoping by `sourceAccountID`
/// keeps the key unique across accounts and providers — server track IDs are
/// only locally unique, so two different Jellyfin/Plex servers (or a Jellyfin
/// and a Plex item) can collide on raw `id` alone and leak one library's
/// lyrics/negatives into another. Falls back to the bare id when no account is
/// attached (e.g. ad-hoc tracks) so behaviour is unchanged for the single-
/// account case.
private func lyricsCacheKey(for track: MusicTrack) -> String {
    if let account = track.sourceAccountID, !account.isEmpty {
        return "\(account)::\(track.id)"
    }
    return track.id
}

/// Builds a lyrics resolver bound to a music provider, mirroring
/// `streamURLResolver`, so the Now Playing lyrics panel works for whichever
/// backend owns the track.
///
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
///     track you've ever played, including remembering that an instrumental
///     piece like Escala's *Palladio* has no lyrics so we don't search for it
///     again (a debounced background re-check still catches a later upload).
///  3. Title heuristic (`isExplicitlyInstrumental`) — short-circuits tracks
///     whose own title says they're instrumental/karaoke without touching the
///     network at all.
///
/// Each result carries its own source tag (Jellyfin/Plex/LRCLIB) for the
/// attribution badge.
@MainActor
func lyricsResolver(for provider: any MusicProvider) -> AudioPlaybackController.LyricsResolver {
    { track, context in
        let key = lyricsCacheKey(for: track)
        // L1: in-memory memo for this session.
        if let cached = await LyricsMemoCache.shared.value(for: key) {
            return AudioPlaybackController.LyricsResolution(
                lyrics: cached,
                staySilent: cached == nil
            )
        }
        // L2: on-disk cache from previous sessions. A negative hit here is the
        // big saving for instrumental tracks — once we've ever asked and found
        // nothing, we skip the network round-trip and stay silent on the UI.
        // `AudioPlaybackController` re-checks remembered negatives in the
        // background (debounced) so a song that *later* gains an LRCLIB upload
        // still surfaces without the user doing anything.
        if let cached = await LyricsDiskCache.shared.cached(key) {
            await LyricsMemoCache.shared.set(cached, for: key)
            return AudioPlaybackController.LyricsResolution(
                lyrics: cached,
                staySilent: cached == nil
            )
        }
        // L3: title heuristic for explicitly-marked instrumental/karaoke
        // tracks. We still persist this through the cache layers so we don't
        // re-evaluate it on every play.
        if isExplicitlyInstrumental(title: track.title) {
            await LyricsMemoCache.shared.set(nil, for: key)
            await LyricsDiskCache.shared.store(nil, for: key)
            return AudioPlaybackController.LyricsResolution(
                lyrics: nil,
                staySilent: true
            )
        }
        // Background prefetch (next track + bulk sweep) skips the expensive
        // LRCLIB title-only fallback to keep the shared rate limiter clear for
        // the visible track; the visible resolve still runs it on-demand.
        let resolution = await resolveSyncedLyrics(
            for: track,
            provider: provider,
            allowTitleOnlyFallback: context == .visible
        )
        // Only persist a result we actually trust. A positive (lyrics found) is
        // always trustworthy; a negative is trustworthy only when at least one
        // source was reachable. An offline/unreachable negative is cached in
        // *neither* L1 nor L2 — otherwise a single wifi blip would poison the
        // memo for the session and a longer outage would burn "no lyrics" onto
        // disk for every song played during it.
        let trustworthy = resolution.lyrics != nil || resolution.isAuthoritative
        if trustworthy {
            await LyricsMemoCache.shared.set(resolution.lyrics, for: key)
            await LyricsDiskCache.shared.store(resolution.lyrics, for: key)
        }
        return AudioPlaybackController.LyricsResolution(
            lyrics: resolution.lyrics,
            // The one-time "No lyrics found" message is allowed only for a
            // definitive negative from a reachable server. An unreachable
            // negative stays silent and keeps re-checking, so a network blip
            // never produces a false "No lyrics found".
            staySilent: resolution.lyrics == nil && !resolution.isAuthoritative
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
        let key = lyricsCacheKey(for: track)
        // Skip if we recently re-checked. 7 days is long enough that an
        // instrumental track on heavy rotation costs effectively zero network
        // traffic, short enough that a newly-uploaded LRCLIB record surfaces
        // within a week of any future play of the song.
        let refreshDebounce: TimeInterval = 60 * 60 * 24 * 7
        if let age = await LyricsDiskCache.shared.entryAge(key), age < refreshDebounce {
            return nil
        }
        // This re-checks the track the user is currently looking at (it went
        // `.silent`), so it earns the full title-only fallback like a visible
        // resolve.
        let resolution = await resolveSyncedLyrics(
            for: track,
            provider: provider,
            allowTitleOnlyFallback: true
        )
        // Don't change anything if the device is offline — leave the existing
        // entry intact and let a future play try again. We only "consume" the
        // debounce window on an authoritative response.
        guard resolution.isAuthoritative else { return nil }
        if let lyrics = resolution.lyrics, !lyrics.isEmpty, lyrics.isSynced {
            // Found new lyrics — promote into both caches so the next play
            // resolves them instantly from L2 with no refresh needed.
            await LyricsMemoCache.shared.set(lyrics, for: key)
            await LyricsDiskCache.shared.store(lyrics, for: key)
            return lyrics
        } else {
            // Still nothing — reset the debounce clock without changing the
            // stored answer so we don't re-check again for another week.
            await LyricsDiskCache.shared.touch(key)
            return nil
        }
    }
}

/// Pure decision for whether a *negative* (no synced lyrics) resolve may be
/// trusted — i.e. cached and allowed to surface the one-time "No lyrics found"
/// message. Extracted as a static, dependency-free function so the authority
/// matrix — the source of the v2→v5 cache-poisoning regression history — is
/// directly unit-testable without SwiftUI/AVFoundation or the network fan-out.
///
/// A negative is authoritative only when every source we needed actually
/// answered *and* we used full effort:
///   - the server must have been reachable (it's always consulted);
///   - LRCLIB must not have been skipped purely for a missing artist;
///   - LRCLIB must not have been skipped because the user has lyrics turned OFF
///     (that skip is a temporary setting, not a verdict: the user can flip lyrics
///     back on and expect a fresh LRCLIB lookup, so a server-only negative formed
///     while disabled is incomplete and must not be baked in — otherwise enabling
///     lyrics and replaying the track would keep reading that poisoned negative
///     for up to 7 days);
///   - if LRCLIB was available it must have been reachable (not throttled /
///     offline / cancelled mid-skip);
///   - and if LRCLIB ran with its title-only fallback disabled (background
///     prefetch) while a usable duration was available, the resolve was
///     reduced-effort: the fallback that finds tracks filed under a *different*
///     artist (a duo/group credit like "Bad Meets Evil", a "Various Artists"
///     soundtrack, a composer-vs-performer classical entry) never ran. Such a
///     negative is INCOMPLETE — trusting it would cache "no lyrics" AND reset
///     the 7-day refresh clock, suppressing the visible play's full fallback for
///     a week on every queue-advanced track. So it must not be authoritative;
///     the visible resolve re-runs the fallback instead of reading a poisoned
///     negative. (No usable duration ⇒ the visible resolve couldn't run the
///     fallback either, so that negative is as complete as it'll get and stays
///     authoritative.)
enum LyricsNegativeAuthority {
    static func isAuthoritative(
        serverReachable: Bool,
        lrclibSkippedForMissingArtist: Bool,
        lrclibSkippedForDisabled: Bool,
        lrclibAvailable: Bool,
        lrclibReachable: Bool,
        allowedTitleOnlyFallback: Bool,
        hasUsableDuration: Bool
    ) -> Bool {
        guard serverReachable else { return false }
        if lrclibSkippedForMissingArtist { return false }
        if lrclibSkippedForDisabled { return false }
        if lrclibAvailable && !lrclibReachable { return false }
        if lrclibAvailable && !allowedTitleOnlyFallback && hasUsableDuration { return false }
        return true
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
    provider: any MusicProvider,
    allowTitleOnlyFallback: Bool
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
    let hasArtist = artist.map { !$0.isEmpty } ?? false
    let lrclibAvailable = lyricsEnabled && hasArtist
    // When lyrics are enabled but the track arrived without an artist (e.g. a
    // queue/album row that only carries the title), we skip LRCLIB and consult
    // the server alone. That makes any resulting negative INCOMPLETE — we never
    // actually asked our best lyrics source. Such a negative must not be treated
    // as authoritative, otherwise the prefetch sweep would burn a permanent
    // "no lyrics" into the cache for songs that LRCLIB has, and a later play
    // with full metadata would keep reading that poisoned negative. See the
    // negative return sites below.
    let lrclibSkippedForMissingArtist = lyricsEnabled && !hasArtist

    enum Source { case server, lrclib, deadline }
    struct Outcome { let source: Source; let lyrics: Lyrics?; let reachable: Bool }

    // Once LRCLIB already holds a synced copy, this is the longest it will wait
    // for a still-pending server before showing what it has. The server's result
    // carries the user's own library attribution so it wins ties, but we never
    // block the visible panel on a slow/unhealthy server beyond this window.
    let serverHeadStart: Duration = .milliseconds(300)

    return await withTaskGroup(of: Outcome.self) { group in
        group.addTask {
            // The provider pre-classifies its own failures: a real "no lyrics"
            // answer from a reachable server returns `nil`, while a transport
            // failure (offline / DNS / TLS / timeout / expired session) is
            // thrown. So any throw here means we could NOT obtain an
            // authoritative verdict — mark it unreachable so callers don't burn
            // a false "no lyrics" into the cache.
            do {
                let lyrics = try await provider.lyrics(for: track.id)
                return Outcome(source: .server, lyrics: lyrics, reachable: true)
            } catch {
                return Outcome(source: .server, lyrics: nil, reachable: false)
            }
        }
        if lrclibAvailable, let artist {
            group.addTask {
                let result = await LRCLIBLyricsProvider().lyricsWithStatus(
                    title: track.title,
                    artist: artist,
                    album: track.albumTitle,
                    duration: track.duration,
                    allowTitleOnlyFallback: allowTitleOnlyFallback
                )
                return Outcome(source: .lrclib, lyrics: result.lyrics, reachable: result.reachable)
            }
        }

        var pendingLRCLIB: Lyrics?
        var sawServer = false
        var serverReachable = false
        var lrclibReachable = false
        var startedDeadline = false
        // A *negative* (no synced lyrics) may only be treated as authoritative —
        // cached, and allowed to surface a one-time "No lyrics found" — when
        // EVERY source we needed actually answered. The server is always
        // consulted; LRCLIB is consulted whenever it's available (lyrics on +
        // artist known). If a needed source was unreachable (offline, timeout,
        // throttled, or cancelled mid-skip) the verdict is INCOMPLETE: stay
        // silent, never cache it, and re-resolve on a later play. This is the
        // core guard against poisoning a song LRCLIB actually has just because
        // the LAN server answered "none" first while the LRCLIB request flaked
        // under load.
        func negativeIsAuthoritative() -> Bool {
            LyricsNegativeAuthority.isAuthoritative(
                serverReachable: serverReachable,
                lrclibSkippedForMissingArtist: lrclibSkippedForMissingArtist,
                lrclibSkippedForDisabled: !lyricsEnabled,
                lrclibAvailable: lrclibAvailable,
                lrclibReachable: lrclibReachable,
                allowedTitleOnlyFallback: allowTitleOnlyFallback,
                hasUsableDuration: (track.duration ?? 0) > 0
            )
        }
        for await outcome in group {
            if outcome.reachable {
                switch outcome.source {
                case .server: serverReachable = true
                case .lrclib: lrclibReachable = true
                case .deadline: break
                }
            }
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
                    // Server still pending: arm a bounded head-start timer so a
                    // slow/unhealthy server can't pin the visible wait. When it
                    // fires we surface the LRCLIB copy we already hold.
                    if !startedDeadline {
                        startedDeadline = true
                        group.addTask {
                            try? await Task.sleep(for: serverHeadStart)
                            return Outcome(source: .deadline, lyrics: nil, reachable: false)
                        }
                    }
                } else if sawServer {
                    // Both sources have reported without synced lyrics; the
                    // negative is authoritative only if both were reachable.
                    return (nil, negativeIsAuthoritative())
                }
            case .deadline:
                // Head-start window elapsed with the server still not producing
                // synced lyrics — commit the LRCLIB copy we've been holding.
                if let pendingLRCLIB {
                    group.cancelAll()
                    return (pendingLRCLIB, true)
                }
            }
        }
        // Group exhausted. A positive `pendingLRCLIB` is always authoritative;
        // a negative is authoritative only when every needed source answered
        // (see negativeIsAuthoritative).
        if pendingLRCLIB != nil {
            return (pendingLRCLIB, true)
        }
        return (nil, negativeIsAuthoritative())
    }
}
#endif
