#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if canImport(UIKit)
import UIKit
import CoreUI
#endif

// `MediaPlayer` transitively imports AudioToolbox, which declares a C `MusicTrack`
// type. Disambiguate so `MusicTrack` here always means our domain model.
public typealias MusicTrack = CoreModels.MusicTrack

/// The app-scoped audio playback engine — **independent** of the video
/// `PlayerViewModel`, which stays full-screen and untouched.
///
/// Owns a single long-lived `AVQueuePlayer` and a manually-managed track queue so
/// it can resolve each track's stream URL on demand, support shuffle/repeat, and
/// drive next/previous. It is created once and injected into the environment, so
/// the mini-player and the Now Playing screen observe the *same* instance.
///
/// Track changes advance the queue (`advanceToNextItem()`) instead of emptying or
/// replacing the player's item. The upcoming track is resolved and *pre-enqueued*
/// behind the current one (the "treadmill", WWDC 2016 §503 / 2019 §501) so
/// AVFoundation prerolls it while the current track still plays; a natural end or
/// a Next then hands off onto that already-buffered item. Keeping the pipeline
/// continuously live — never empty, never stalled on a cold fetch — is what
/// PRESERVES the output route. That is essential for AirPlay 2: `removeAllItems()`,
/// `replaceCurrentItem(with:)`, or advancing onto an unbuffered item tears the
/// route to the speaker down, so the next track is silent (and the speaker stays
/// dead until it's physically reconnected), while seeking within the same item —
/// which never swaps the item — is unaffected. As a safety net for transitions
/// that can't be pre-enqueued (arbitrary jumps), route-change and interruption
/// observers re-activate the session and resume if the system parks playback.
///
/// tvOS background audio (the part the video flow never does):
///  * configures `AVAudioSession` `.playback` (with the `.longFormAudio`
///    route-sharing policy) + `setActive(true)` so audio keeps playing while the
///    user browses other screens or the screensaver starts;
///  * publishes `MPNowPlayingInfoCenter` (title/artist/album, artwork, duration,
///    elapsed, playback rate) for the system Now Playing card in Control Center;
///  * wires `MPRemoteCommandCenter` (play/pause/toggle/next/previous/seek) so the
///    Siri Remote transport controls drive the queue.
@MainActor
@Observable
public final class AudioPlaybackController {
    public enum RepeatMode: Sendable, CaseIterable {
        case off, all, one
    }

    /// Closure that resolves a playable stream (URL + fidelity) for a track
    /// (provider-backed), allowing the engine to stay decoupled from any concrete
    /// provider.
    public typealias StreamURLResolver = @MainActor (MusicTrack) async -> ResolvedStream?

    /// Reports a playback lifecycle event (`start`/`progress`/`pause`/`unpause`/
    /// `stop`) for a track to its owning server, so listening in Plozz stamps the
    /// user's server-side play history — which is what feeds the "Recently
    /// Played" rail. Bound to the play session's provider (a queue is
    /// single-account, exactly like `StreamURLResolver`). Best-effort: the
    /// implementation swallows failures, so a reporting error never disrupts
    /// playback (mirrors the video player's non-fatal reporting).
    public typealias PlaybackReporter = @MainActor (MusicTrack, PlaybackEvent, TimeInterval, TimeInterval) async -> Void

    /// Resolves a track's lyrics (provider-backed). The result reports both
    /// the lyrics (or `nil` when none are available) and whether the UI should
    /// *stay silent* about a `nil` — i.e. suppress the one-time "No lyrics
    /// found" message. That happens when the negative came from a cache hit / an
    /// instrumental heuristic, **or** when we couldn't reach a server at all
    /// (offline). In every silent case the controller stays in `.silent` (no
    /// spinner, no message) and kicks off a background re-check via
    /// `LyricsRefresher`, so a song that later receives an LRCLIB upload — or
    /// one we simply couldn't fetch while offline — surfaces silently on a
    /// future play.
    public typealias LyricsResolver = @MainActor (MusicTrack, LyricsResolveContext) async -> LyricsResolution

    /// Why lyrics are being resolved, which tunes how hard the LRCLIB fallback
    /// works. `visible` is the track the user is actually looking at (the Now
    /// Playing panel) and earns the thorough title-only + duration-matched
    /// fallback that rescues songs filed under a different artist name (a duo
    /// alias, "Various Artists", composer-vs-performer). `prefetch` is
    /// background queue-warming (next track + bulk sweep) where that extra
    /// per-track fan-out isn't worth the shared LRCLIB rate-limiter contention,
    /// so it sticks to the cheaper artist-qualified lookups — any track that
    /// needs the fallback still gets it on-demand the instant it becomes visible.
    public enum LyricsResolveContext: Sendable {
        case visible
        case prefetch
    }

    /// Background re-check for a track whose cached answer was negative.
    /// Returns lyrics only when the *new* lookup found something the cache
    /// didn't have. Implementations are expected to debounce so the same
    /// instrumental isn't re-queried on every play.
    public typealias LyricsRefresher = @MainActor (MusicTrack) async -> Lyrics?

    /// Outcome of a `LyricsResolver` call.
    public struct LyricsResolution: Sendable, Equatable {
        public let lyrics: Lyrics?
        /// When `lyrics` is `nil`, true means the UI should stay silent rather
        /// than flash "No lyrics found": the negative came from a cache hit, an
        /// instrumental heuristic, or an unreachable server (offline). All of
        /// those drive the "stay silent + re-check in the background" behaviour.
        /// Only a *definitive first-time* negative from a reachable server sets
        /// this `false`, which is the lone path allowed to show the message.
        public let staySilent: Bool

        public init(lyrics: Lyrics?, staySilent: Bool = false) {
            self.lyrics = lyrics
            self.staySilent = staySilent
        }
    }

    /// Loading state of the current track's lyrics, observed by the Now Playing
    /// lyrics panel.
    public enum LyricsState: Sendable, Equatable {
        /// No lyrics requested yet (nothing playing, or no resolver wired).
        case idle
        /// A fetch is in flight for the current track.
        case loading
        /// Lyrics were found.
        case loaded(Lyrics)
        /// The fetch completed but the track has no lyrics.
        case unavailable
        /// We've previously resolved this track to "no lyrics" and are trusting
        /// that. UI stays exactly as if lyrics were disabled — no panel, no
        /// spinner, no "No lyrics found" message — while a background refresh
        /// silently re-checks. If the refresh finds new lyrics this transitions
        /// to `.loaded`; otherwise it stays `.silent`.
        case silent

        /// Whether usable lyrics are available (drives the toggle's enabled state).
        public var hasLyrics: Bool {
            if case .loaded = self { return true }
            return false
        }
    }

    /// The result of resolving a track: a playable URL plus the fidelity the
    /// stream delivers, so the UI can show a quality badge.
    public struct ResolvedStream: Sendable {
        public let url: URL
        public let quality: PlaybackQuality?
        public init(url: URL, quality: PlaybackQuality? = nil) {
            self.url = url
            self.quality = quality
        }
    }

    // MARK: Observable state

    /// The current play order (already shuffled when `isShuffled` is on).
    public private(set) var queue: [MusicTrack] = []
    /// Index of the current track within `queue`.
    public private(set) var index: Int = 0
    public private(set) var isPlaying: Bool = false
    public private(set) var isShuffled: Bool = false
    public var repeatMode: RepeatMode = .off
    /// Elapsed time of the current track, in seconds.
    public private(set) var currentTime: TimeInterval = 0
    /// Duration of the current track, in seconds (0 until known).
    public private(set) var duration: TimeInterval = 0
    /// Fidelity of the currently playing stream (direct-play/lossless vs
    /// transcode), surfaced in the Now Playing UI. `nil` until resolved or when
    /// the provider doesn't report it.
    public private(set) var currentQuality: PlaybackQuality?
    /// Loading state of the current track's lyrics. `.loaded` when found,
    /// `.unavailable` when the track has none, driving the Now Playing lyrics
    /// panel and the lyrics toggle's enabled state.
    public private(set) var lyricsState: LyricsState = .idle
    /// Increments every time a *new* playback session begins (a `play` /
    /// `playShuffled` call). The Music tab observes this to auto-present the
    /// full-screen Now Playing player when the user starts a song.
    public private(set) var playbackStartToken: Int = 0
    /// Increments once a track's **stop** report has actually been delivered to
    /// its server — the moment the play is recorded (Jellyfin marks it played,
    /// Plex scrobbles it). The Music landing view observes this to refresh its
    /// "Recently Played" rail so listening shows up without an app relaunch.
    public private(set) var recentPlayReportToken: Int = 0
    /// Whether anything is loaded — drives mini-player visibility. The
    /// mini-player and Music tab are absent whenever this is `false`.
    public var hasActivePlayback: Bool { !queue.isEmpty }

    public var currentTrack: MusicTrack? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    public var upNext: [MusicTrack] {
        guard index + 1 < queue.count else { return [] }
        return Array(queue[(index + 1)...])
    }

    // MARK: Private

    private let player = AVQueuePlayer()
    private var resolver: StreamURLResolver?
    private var lyricsResolver: LyricsResolver?
    private var lyricsRefresher: LyricsRefresher?
    private var lyricsLoadTask: Task<Void, Never>?
    /// Background re-check for the current track when we resolved from a
    /// remembered negative. Lets a song that was previously instrumental but
    /// has since gained an LRCLIB upload surface silently mid-play, without
    /// ever flashing "Searching for lyrics…" or "No lyrics found".
    private var lyricsRefreshTask: Task<Void, Never>?
    /// Fire-and-forget warmup for the *next* queued track's lyrics, so by the
    /// time the user advances it's already a memo-cache hit. Cancelled and
    /// replaced on every track change so a runaway skip-skip-skip session
    /// only ever has one prefetch in flight.
    private var lyricsPrefetchTask: Task<Void, Never>?
    /// Slow background sweep that walks the *rest* of the queue after the
    /// immediate next track, warming the lyrics cache one track at a time
    /// with a small delay between each so we don't hammer LRCLIB or the
    /// user's server. Cancelled and replaced on every track / queue change.
    /// Cache hits cost ~0ms so a re-played album finishes its sweep almost
    /// instantly; a fresh album incurs ~one polite request per track.
    private var lyricsBulkPrefetchTask: Task<Void, Never>?
    /// Pause between successive bulk-prefetch lookups. This spaces out *tracks*;
    /// the actual per-request LRCLIB politeness is enforced separately by the
    /// shared token-bucket rate limiter inside `LRCLIBLyricsProvider`, so a
    /// track's internal fan-out can't burst past the global budget regardless of
    /// this value. Tuned so a long playlist still finishes warming reasonably
    /// soon without making the sweep feel like a network crawl.
    private static let bulkPrefetchSpacing: Duration = .milliseconds(1500)
    /// Upper bound on how many upcoming tracks the background sweep warms per
    /// run. Caps the work scheduled for very long playlists/albums; tracks past
    /// this point are warmed lazily as the user advances (each track change
    /// re-runs the sweep from the new position).
    private static let maxBulkPrefetch = 30
    /// How often to emit a periodic `.progress` report while a track plays. Keeps
    /// the server's now-playing position fresh and lets Plex auto-scrobble as the
    /// timeline nears the end, without spamming (the time observer fires 4×/sec).
    private static let progressReportInterval: TimeInterval = 10
    /// The unshuffled queue, so toggling shuffle off restores original order.
    private var orderedQueue: [MusicTrack] = []
    private var playSessionID: String?
    /// Reports play lifecycle events to the current session's server
    /// (best-effort). Bound to the play session's provider; `nil` disables
    /// reporting (e.g. a provider that isn't a `MediaProvider`).
    private var reporter: PlaybackReporter?
    /// A second, provider-INDEPENDENT reporter for the global Last.fm scrobbler.
    /// Last.fm is one account per user (not tied to Plex/Jellyfin), so it fans out
    /// from the same lifecycle events as `reporter` but is set once (by AppShell,
    /// capturing the stable scrobbler) rather than rebound per play session.
    public var scrobbleObserver: PlaybackReporter?
    /// The track we've reported a `.start` for and not yet a `.stop`. Guards the
    /// stop/pause/progress helpers so they only ever fire for a live, started
    /// track, and lets us stop the OUTGOING track before starting the next one
    /// (so the server's now-playing/history stays coherent across a hand-off).
    private var reportedTrack: MusicTrack?
    /// Bumped on every `startCurrent` transition. A resolving transition captures
    /// this value and aborts if a newer transition superseded it, so rapid skips
    /// don't leave intermediate tracks with a `.start` and no matching `.stop`.
    private var trackTransitionGeneration = 0
    /// When we last emitted a throttled `.progress` report. The time observer
    /// fires 4×/sec but we only ping the server every `progressReportInterval`.
    private var lastProgressReportAt: Date?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var sessionConfigured = false
    private var remoteCommandsActive = false
    #if canImport(MediaPlayer)
    /// Current track artwork, retained so each `nowPlayingInfo` rebuild can
    /// re-attach it (assigning `nowPlayingInfo` replaces the whole dictionary).
    private var currentArtwork: MPMediaItemArtwork?
    #endif
    private var artworkLoadTask: Task<Void, Never>?
    /// The next track pre-enqueued *behind* the current one — the "treadmill"
    /// (WWDC 2016 §503 / 2019 §501). Resolving the upcoming track's URL and
    /// `insert`ing its item into the live queue ahead of time lets AVFoundation
    /// preroll it while the current track still plays, so a natural end or a Next
    /// hands off via `advanceToNextItem()` onto an already-buffered item. That is
    /// the ONE transition that reliably keeps the AirPlay 2 route alive: the
    /// pipeline never empties and never stalls on a cold fetch. `item` is `nil`
    /// while the URL is still resolving (intent is recorded synchronously so
    /// re-entrant prepares dedupe).
    private struct PreparedNext {
        let trackID: MusicTrack.ID
        var item: AVPlayerItem?
        var quality: PlaybackQuality?
    }
    private var preparedNext: PreparedNext?
    /// Coalesces rapid user-initiated skips into a single player transition. Each
    /// Next/Previous press only moves `index` and (re)schedules this task; the
    /// actual `startCurrent()` runs once the presses settle. Spamming skip would
    /// otherwise fire an `advanceToNextItem()` per press, and on AirPlay 2 each
    /// transition interrupts the previous one's route negotiation mid-flight,
    /// tearing the speaker connection down. Debouncing keeps the CURRENT track
    /// playing (route alive) until the user lands, then transitions just once.
    private var startTask: Task<Void, Never>?
    /// True while a debounced skip is pending — the UI shows the target track but
    /// the player is still on the outgoing one, so the time observer freezes the
    /// scrubber at 0 instead of showing the old track's position under the new
    /// title. Cleared once the pending `startCurrent()` completes.
    private var startPending = false
    /// How long to wait for skips to settle before actually retargeting the
    /// player. Long enough to coalesce a burst of presses, short enough that a
    /// single deliberate skip still feels responsive.
    private static let skipDebounce: Duration = .milliseconds(350)
    /// Recovery observers: if a track transition makes the system tear down or
    /// reconfigure the (AirPlay) route, re-activate the session and resume so the
    /// speaker doesn't stay silent until it's physically reconnected.
    private var routeChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    /// Last `timeControlStatus` we logged, so the time observer only records
    /// *transitions* (playing→waiting→paused) rather than 4×/sec noise. A
    /// playing→waiting→paused slide with no user pause is the fingerprint of an
    /// AirPlay route drop.
    private var lastLoggedTimeControl: AVPlayer.TimeControlStatus?

    public init() {
        player.actionAtItemEnd = .none
        installTimeObserver()
        installRouteRecoveryObservers()
        // Touch the diagnostics logger at launch so the log file exists (and is
        // pullable) even before the first playback, and so each launch is marked.
        diag("session", "AudioPlaybackController init — route=\(routeSummary())")
    }

    // MARK: Diagnostics

    /// Appends an audio event to the pullable diagnostics log (see
    /// `AudioDiagnostics`). Cheap; called at every transition/route event so a
    /// pulled log reconstructs exactly what happened around an AirPlay break.
    private func diag(_ category: String, _ message: String) {
        AudioDiagnostics.shared.log(category, message)
    }

    /// Current output route as a one-liner for the log (AirPlay port + name).
    private func routeSummary() -> String {
        #if canImport(AVFoundation) && !os(macOS)
        return AudioDiagnostics.shared.currentRouteDescription()
        #else
        return "n/a"
        #endif
    }

    /// The player's live playback state, for logging around a transition. Shows
    /// whether it's playing / paused / waiting, and — when waiting — WHY, which is
    /// the key tell for an AirPlay stall (`.toMinimizeStalls` = buffering,
    /// `.evaluatingBufferingRate`, `.noItemToPlay`, etc.).
    private func playerStateSummary() -> String {
        let status: String
        switch player.timeControlStatus {
        case .paused: status = "paused"
        case .waitingToPlayAtSpecifiedRate: status = "waiting"
        case .playing: status = "playing"
        @unknown default: status = "unknown"
        }
        var parts = ["timeControl=\(status)", "rate=\(player.rate)", "items=\(player.items().count)"]
        if let reason = player.reasonForWaitingToPlay {
            parts.append("waitReason=\(reason.rawValue)")
        }
        if let err = player.error {
            parts.append("playerError=\(err.localizedDescription)")
        }
        if let itemErr = player.currentItem?.error {
            parts.append("itemError=\(itemErr.localizedDescription)")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Public API

    /// Starts playing `tracks` from `startIndex`. `resolveStreamURL` maps each
    /// track to its playable URL (the owning provider's audio stream), called
    /// lazily as the queue advances so we never resolve a whole album up front.
    public func play(
        tracks: [MusicTrack],
        startIndex: Int,
        playSessionID: String? = nil,
        resolveStreamURL: @escaping StreamURLResolver,
        resolveLyrics: LyricsResolver? = nil,
        refreshLyrics: LyricsRefresher? = nil,
        reportPlayback: PlaybackReporter? = nil
    ) {
        guard !tracks.isEmpty else { return }
        let clampedStart = min(max(startIndex, 0), tracks.count - 1)
        // Tapping the song that's already playing shouldn't restart it — just
        // surface the full-screen player again (the Music tab observes the token).
        if hasActivePlayback, currentTrack?.id == tracks[clampedStart].id {
            playbackStartToken &+= 1
            return
        }
        // Close the outgoing queue's live track on ITS OWN provider before we swap
        // in the new queue's reporter — otherwise a cross-account hand-off would
        // route its stop (and any scrobble) to the wrong server.
        reportStopIfNeeded(position: currentTime)
        self.resolver = resolveStreamURL
        self.lyricsResolver = resolveLyrics
        self.lyricsRefresher = refreshLyrics
        self.reporter = reportPlayback
        self.playSessionID = playSessionID
        self.orderedQueue = tracks
        self.isShuffled = false
        self.queue = tracks
        self.index = clampedStart
        configureSessionIfNeeded()
        playbackStartToken &+= 1
        scheduleStart(debounced: false)
    }

    /// Plays the whole list shuffled, starting on a random track.
    public func playShuffled(
        tracks: [MusicTrack],
        playSessionID: String? = nil,
        resolveStreamURL: @escaping StreamURLResolver,
        resolveLyrics: LyricsResolver? = nil,
        refreshLyrics: LyricsRefresher? = nil,
        reportPlayback: PlaybackReporter? = nil
    ) {
        guard !tracks.isEmpty else { return }
        // Close the outgoing queue's live track on ITS OWN provider before we swap
        // in the new queue's reporter — otherwise a cross-account hand-off would
        // route its stop (and any scrobble) to the wrong server.
        reportStopIfNeeded(position: currentTime)
        self.resolver = resolveStreamURL
        self.lyricsResolver = resolveLyrics
        self.lyricsRefresher = refreshLyrics
        self.reporter = reportPlayback
        self.playSessionID = playSessionID
        self.orderedQueue = tracks
        self.isShuffled = true
        self.queue = tracks.shuffled()
        self.index = 0
        configureSessionIfNeeded()
        playbackStartToken &+= 1
        scheduleStart(debounced: false)
    }

    public func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    public func resume() {
        guard hasActivePlayback else { return }
        // Re-assert the audio session in case it was deactivated while paused,
        // and use `playImmediately(atRate:)` so playback resumes now instead of
        // getting stuck in AVPlayer's stall-avoidance wait state.
        #if canImport(AVFoundation) && !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.playImmediately(atRate: 1.0)
        isPlaying = true
        reportPauseState(paused: false)
        #if canImport(MediaPlayer)
        updateNowPlayingInfo()
        #endif
    }

    public func pause() {
        player.pause()
        isPlaying = false
        reportPauseState(paused: true)
        #if canImport(MediaPlayer)
        updateNowPlayingInfo()
        #endif
    }

    public func next() {
        advance(by: 1, userInitiated: true)
    }

    public func previous() {
        // Match the platform convention: restart the track if we're more than a
        // few seconds in, otherwise step back.
        if currentTime > 3 {
            Task { await seek(to: 0) }
            return
        }
        advance(by: -1, userInitiated: true)
    }

    /// Jumps to a specific queue position (e.g. tapping a row in Up Next).
    public func play(at queueIndex: Int) {
        guard queue.indices.contains(queueIndex) else { return }
        index = queueIndex
        scheduleStart(debounced: false)
    }

    public func seek(to seconds: TimeInterval) async {
        let target = max(0, seconds)
        await player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = target
        #if canImport(MediaPlayer)
        updateNowPlayingInfo()
        #endif
    }

    public func toggleShuffle() {
        setShuffle(!isShuffled)
    }

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        // Repeat mode changes what plays next (a wrap-around track, or the same
        // track under repeat-one), so re-arm the treadmill for the new mode.
        clearPreparedNext(removeFromPlayer: true)
        prepareNextInQueue()
    }

    /// Stops playback and clears the queue — hides the mini-player.
    public func stop() {
        // Report the current track's stop before we tear down so the server
        // closes its now-playing session and records the play position.
        reportStopIfNeeded(position: currentTime)
        startTask?.cancel()
        startPending = false
        player.pause()
        player.removeAllItems()
        preparedNext = nil
        isPlaying = false
        queue = []
        orderedQueue = []
        index = 0
        currentTime = 0
        duration = 0
        currentQuality = nil
        lyricsLoadTask?.cancel()
        lyricsRefreshTask?.cancel()
        lyricsPrefetchTask?.cancel()
        lyricsBulkPrefetchTask?.cancel()
        lyricsState = .idle
        // Relinquish the system Play/Pause button so the video player can
        // receive it again once music is no longer playing.
        disableRemoteCommands()
    }

    // MARK: Shuffle

    private func setShuffle(_ on: Bool) {
        guard on != isShuffled else { return }
        let current = currentTrack
        if on {
            var rest = orderedQueue
            if let current, let pos = rest.firstIndex(of: current) {
                rest.remove(at: pos)
                queue = [current] + rest.shuffled()
            } else {
                queue = orderedQueue.shuffled()
            }
            index = 0
        } else {
            queue = orderedQueue
            index = current.flatMap { queue.firstIndex(of: $0) } ?? 0
        }
        isShuffled = on
        // The play order changed under the current track, so whatever we'd
        // pre-enqueued as "next" is now wrong — drop it and re-arm the treadmill.
        clearPreparedNext(removeFromPlayer: true)
        prepareNextInQueue()
    }

    // MARK: Queue advancement

    private func advance(by offset: Int, userInitiated: Bool) {
        guard hasActivePlayback else { return }
        let next = index + offset
        if next < 0 {
            index = 0
            scheduleStart(debounced: userInitiated)
            return
        }
        if next >= queue.count {
            // Past the end: wrap on repeat-all, otherwise stop at the last track.
            if repeatMode == .all {
                index = 0
                scheduleStart(debounced: userInitiated)
            } else if userInitiated {
                index = queue.count - 1
                scheduleStart(debounced: userInitiated)
            } else {
                pause()
            }
            return
        }
        index = next
        scheduleStart(debounced: userInitiated)
    }

    /// Called when the current item finishes on its own.
    private func handleItemDidEnd() {
        // A natural end means the track played to completion — report a stop at
        // full duration so the server marks it *played* (the signal that feeds
        // "Recently Played"). Do it before advancing; startCurrent's own stop
        // then no-ops because reportedTrack is already cleared.
        reportStopIfNeeded(position: duration > 0 ? duration : currentTime)
        if repeatMode == .one {
            scheduleStart(debounced: false)
        } else {
            advance(by: 1, userInitiated: false)
        }
    }

    /// (Re)schedules a start of the current index. User-initiated skips are
    /// debounced so a burst of Next/Previous presses collapses into ONE player
    /// transition once the user lands — critical for AirPlay 2, where firing a
    /// transition per press interrupts each item's route negotiation mid-flight
    /// and drops the speaker. During the debounce the outgoing track keeps
    /// playing (route stays alive) and the scrubber freezes at 0 under the new
    /// title. Natural ends and explicit taps pass `debounced: false` — they're
    /// never rapid and want the immediate, seamless treadmill hand-off. Bumping
    /// the generation here supersedes any start still resolving so it bails
    /// instead of transitioning to a track the user has already skipped past.
    private func scheduleStart(debounced: Bool) {
        diag("skip", "scheduleStart debounced=\(debounced) index=\(index) track=\"\(currentTrack?.title ?? "nil")\" route=\(routeSummary())")
        startTask?.cancel()
        trackTransitionGeneration &+= 1
        if debounced {
            startPending = true
            currentTime = 0
            duration = currentTrack?.duration ?? 0
        }
        startTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: Self.skipDebounce)
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            await self.startCurrent()
            if !Task.isCancelled { self.startPending = false }
        }
    }

    private func startCurrent() async {
        guard let track = currentTrack, let resolver else { return }
        // Supersede guard: a rapid skip or a new queue spawns another startCurrent
        // while this one is still resolving. Capture this transition's generation so
        // a stale task bails after the await instead of stopping/starting a track the
        // user has already skipped past (which would leak a start with no stop).
        trackTransitionGeneration &+= 1
        let generation = trackTransitionGeneration
        loadLyrics(for: track)

        // FAST PATH — the treadmill hand-off. This track was pre-enqueued behind
        // the outgoing one (see `prepareNextInQueue`) and has been prerolling in
        // the live pipeline, so it's already the player's *next* item and buffered.
        // Advancing onto an already-ready queued item is the ONLY track change that
        // reliably preserves the AirPlay 2 route (WWDC 2016 §503 / 2019 §501): no
        // resolve, no cold insert, and crucially NO `playImmediately` — the item is
        // ready, so a plain `play()` starts it without forcing past AVPlayer's
        // stall-avoidance (forcing an empty AirPlay buffer is what dropped the route
        // and produced the "seek bar advances but it's silent" symptom).
        if let prepared = preparedNext, prepared.trackID == track.id,
           let item = prepared.item,
           player.items().count >= 2, player.items()[1] === item {
            diag("start", "FAST-PATH gen=\(generation) track=\"\(track.title)\" route=\(routeSummary()) preState=[\(playerStateSummary())]")
            // Close the OUTGOING track's session (its skip point on a manual next,
            // or ≈duration on a natural end — where handleItemDidEnd already
            // reported it and this no-ops).
            reportStopIfNeeded(position: currentTime)
            enableRemoteCommands()
            currentQuality = prepared.quality
            preparedNext = nil
            player.advanceToNextItem()
            observeEnd(of: item)
            player.play()
            diag("start", "FAST-PATH post-advance/play route=\(routeSummary()) state=[\(playerStateSummary())]")
            await finishStart(track: track)
            return
        }

        // SLOW / HARD PATH — an arbitrary jump (new queue, tap-to-play, previous,
        // repeat-one restart, shuffle/wrap) whose target wasn't pre-enqueued. We
        // still keep the player instance and never empty it to `nil`: insert the
        // fresh item behind the still-playing one, wait until it has buffered
        // enough for a smooth AirPlay hand-off, then advance. If the route can't be
        // preserved here the recovery observers pick it back up.
        currentQuality = nil
        diag("start", "HARD-PATH gen=\(generation) track=\"\(track.title)\" route=\(routeSummary()) preState=[\(playerStateSummary())] — resolving URL")
        guard let resolved = await resolver(track),
              generation == trackTransitionGeneration else {
            diag("start", "HARD-PATH aborted (resolve failed or superseded) gen=\(generation) current=\(trackTransitionGeneration)")
            return
        }
        reportStopIfNeeded(position: currentTime)
        currentQuality = resolved.quality
        // Claim the system remote/Now Playing controls only once music is
        // actually playing. Registering them eagerly (e.g. at app launch) makes
        // tvOS route the Siri Remote's Play/Pause button to the command center
        // instead of delivering it to the foreground view, which silently breaks
        // the video player's own Play/Pause handling.
        enableRemoteCommands()
        let item = AVPlayerItem(url: resolved.url)
        if let current = player.currentItem {
            // Drop any stale pre-enqueued item so it doesn't linger in the queue
            // (this jump supersedes whatever "next" we'd guessed).
            clearPreparedNext(removeFromPlayer: true)
            player.insert(item, after: current)
            diag("start", "HARD-PATH inserted, waiting to buffer route=\(routeSummary())")
            await waitUntilReadyToPlay(item)
            // A rapid skip / new queue may have superseded us while buffering. Drop
            // the item we speculatively queued and let the newer transition win.
            guard generation == trackTransitionGeneration else {
                player.remove(item)
                diag("start", "HARD-PATH superseded after buffering gen=\(generation) current=\(trackTransitionGeneration) — dropped item")
                return
            }
            diag("start", "HARD-PATH buffered itemStatus=\(item.status.rawValue) likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp) bufferFull=\(item.isPlaybackBufferFull) — advancing")
            player.advanceToNextItem()
            observeEnd(of: item)
            // Ready item → plain `play()`; don't force past stall-avoidance on a
            // freshly-advanced AirPlay route.
            player.play()
            diag("start", "HARD-PATH post-advance/play route=\(routeSummary()) state=[\(playerStateSummary())]")
        } else {
            // Cold start — no current item and therefore no route to protect yet, so
            // `playImmediately` is safe and avoids parking in the wait state.
            player.insert(item, after: nil)
            observeEnd(of: item)
            player.playImmediately(atRate: 1.0)
            diag("start", "COLD-START route=\(routeSummary()) state=[\(playerStateSummary())]")
        }
        await finishStart(track: track)
    }

    /// Shared tail run once `player.currentItem` is the intended `track` (via either
    /// the treadmill hand-off or a hard advance): publishes UI/Now-Playing state,
    /// opens the server-side now-playing session, and — importantly — pre-enqueues
    /// the *following* track so the next advance can take the seamless fast path.
    private func finishStart(track: MusicTrack) async {
        isPlaying = true
        currentTime = 0
        duration = track.duration ?? 0
        // The new track is now playing — open its server-side now-playing session.
        reportStart(track)
        // Warm the treadmill: resolve + enqueue the upcoming track right away so it
        // prerolls while this one plays. Done before the artwork/duration awaits so
        // even a short track has its successor ready in time.
        prepareNextInQueue()
        #if canImport(MediaPlayer)
        currentArtwork = nil
        // Try to have artwork ready BEFORE the first publish so tvOS's transient
        // top-corner Now Playing banner (a one-shot snapshot taken when audio
        // starts) shows the album art, like Apple Music/Spotify. Bounded so a
        // slow artwork download never holds up the Now Playing card itself.
        #if canImport(UIKit)
        if let artURL = track.artworkURL,
           let image = await bannerArtworkImage(artURL),
           currentTrack?.id == track.id {
            currentArtwork = Self.makeArtwork(from: image)
        }
        #endif
        updateNowPlayingInfo()
        #endif
        loadArtwork(for: track)
        await refreshDuration()
        #if canImport(MediaPlayer)
        updateNowPlayingInfo()
        #endif
    }

    /// The track a natural end or a Next would advance to — the one worth
    /// pre-enqueuing. `nil` when there's nothing to preroll (end of a non-repeating
    /// queue, or repeat-one where the same item simply replays).
    private func sequentialNextTrack() -> MusicTrack? {
        guard hasActivePlayback else { return nil }
        if repeatMode == .one { return nil }
        let next = index + 1
        if queue.indices.contains(next) { return queue[next] }
        // Past the end: repeat-all loops back to the top (but a single-track queue
        // has no distinct "next" to enqueue).
        if repeatMode == .all, queue.count > 1 { return queue.first }
        return nil
    }

    /// Resolves and inserts the upcoming track behind the current item so it
    /// prerolls in the live pipeline (the treadmill). Idempotent per target track;
    /// the async resolve bails if a newer transition superseded it, preventing a
    /// double-insert during rapid skipping.
    private func prepareNextInQueue() {
        guard let resolver, let nextTrack = sequentialNextTrack() else {
            clearPreparedNext(removeFromPlayer: true)
            return
        }
        // Already prepared (or preparing) for this exact track — leave it be.
        if preparedNext?.trackID == nextTrack.id { return }
        clearPreparedNext(removeFromPlayer: true)
        let generation = trackTransitionGeneration
        let trackID = nextTrack.id
        // Record intent synchronously so a re-entrant prepare dedupes even before
        // the URL resolves; the item is filled in once resolved + inserted.
        preparedNext = PreparedNext(trackID: trackID, item: nil, quality: nil)
        Task { [weak self] in
            guard let self else { return }
            guard let resolved = await resolver(nextTrack),
                  self.trackTransitionGeneration == generation,
                  self.preparedNext?.trackID == trackID,
                  self.preparedNext?.item == nil else { return }
            let item = AVPlayerItem(url: resolved.url)
            guard self.player.canInsert(item, after: self.player.currentItem) else {
                self.clearPreparedNext()
                return
            }
            self.player.insert(item, after: self.player.currentItem)
            self.preparedNext = PreparedNext(trackID: trackID, item: item, quality: resolved.quality)
        }
    }

    /// Forgets the pre-enqueued track, optionally removing its (still-queued) item
    /// from the player so a hard jump doesn't leave a stale item behind the new one.
    private func clearPreparedNext(removeFromPlayer: Bool = false) {
        if removeFromPlayer, let item = preparedNext?.item,
           player.items().contains(where: { $0 === item }) {
            player.remove(item)
        }
        preparedNext = nil
    }

    /// Waits until `item` has both loaded (`.readyToPlay`) *and* buffered enough to
    /// keep up before a hard `advanceToNextItem()`. Gating on `.readyToPlay` alone
    /// is only local readiness; AirPlay has far higher startup latency, so advancing
    /// with a locally-ready-but-AirPlay-empty buffer stalls the speaker and drops
    /// the route. Runs on the main actor; `Task.sleep` suspends without blocking.
    private func waitUntilReadyToPlay(_ item: AVPlayerItem, timeout: TimeInterval = 8.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if item.status == .failed { return }
            if item.status == .readyToPlay,
               item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    /// Re-resolves the current track's lyrics from scratch. Used when the user
    /// turns the lyrics setting back ON from Now Playing: the resolve that ran
    /// while lyrics were disabled deliberately skipped LRCLIB (our main source),
    /// so the current `.silent`/`.unavailable` verdict is stale — a fresh lookup
    /// now consults LRCLIB and can surface lyrics for the track on screen without
    /// waiting for the user to skip to the next one. No-op when nothing's playing.
    public func reloadCurrentTrackLyrics() {
        guard let track = currentTrack else { return }
        loadLyrics(for: track)
    }

    /// Fetches lyrics for `track` off the critical path, publishing `lyricsState`
    /// as it resolves. Cancels any in-flight load so a fast next/previous never
    /// shows a stale track's lyrics. With no resolver wired, stays `.unavailable`.
    ///
    /// On a *remembered negative* (a cached or heuristically-determined "no
    /// lyrics"), the visible state goes straight to `.silent` — no spinner,
    /// no "No lyrics found" message — and we silently re-check in the
    /// background so a song that has since gained an LRCLIB upload surfaces
    /// without the user having to do anything. The refresher itself debounces,
    /// so playing the same instrumental repeatedly isn't network traffic.
    private func loadLyrics(for track: MusicTrack) {
        lyricsLoadTask?.cancel()
        lyricsRefreshTask?.cancel()
        lyricsPrefetchTask?.cancel()
        lyricsBulkPrefetchTask?.cancel()
        guard let lyricsResolver else {
            lyricsState = .unavailable
            return
        }
        lyricsState = .loading
        let trackID = track.id
        lyricsLoadTask = Task { [weak self] in
            let resolution = await lyricsResolver(track, .visible)
            guard !Task.isCancelled, let self else { return }
            // Ignore a result that arrived after the user moved on.
            guard self.currentTrack?.id == trackID else { return }
            let lyrics = resolution.lyrics
            // Only synced lyrics are usable on a TV (no manual scrolling), so an
            // unsynced result is treated as "no lyrics" — the player stays centered.
            let usable = (lyrics?.isEmpty == false && lyrics?.isSynced == true) ? lyrics : nil
            if let usable {
                self.lyricsState = .loaded(usable)
            } else if resolution.staySilent {
                // Stay silent (panel hidden, no message) and re-check quietly.
                self.lyricsState = .silent
                self.refreshLyricsInBackground(for: track)
            } else {
                // First-time resolution that really came up empty — show the
                // "No lyrics found" state once so the user sees a definitive
                // answer. Future plays will be silent.
                self.lyricsState = .unavailable
            }
            // Warm the cache for the next queued track so advancing is instant,
            // then a slow background sweep walks the rest of the queue so a
            // long album/playlist gets fully cached before the user reaches it.
            self.prefetchNextTrackLyrics()
            self.prefetchRestOfQueueLyrics()
        }
    }

    /// Silent background re-check for a track whose visible state is `.silent`.
    /// If the refresher returns synced lyrics, transitions to `.loaded`
    /// (assuming the track is still current); otherwise leaves the state
    /// alone — the user never sees a flash. Refresher is expected to debounce,
    /// so this is safe to call on every play.
    private func refreshLyricsInBackground(for track: MusicTrack) {
        guard let lyricsRefresher else { return }
        let trackID = track.id
        lyricsRefreshTask = Task { [weak self] in
            let refreshed = await lyricsRefresher(track)
            guard !Task.isCancelled, let self else { return }
            guard self.currentTrack?.id == trackID else { return }
            guard let refreshed, !refreshed.isEmpty, refreshed.isSynced else { return }
            // Only promote when we're still in `.silent`. If the user toggled
            // lyrics off or another load supersceded us, leave that alone.
            if case .silent = self.lyricsState {
                self.lyricsState = .loaded(refreshed)
            }
        }
    }

    /// Kicks off a background lookup for the immediate next queued track so it
    /// resolves from `LyricsMemoCache` instantly when the user advances. Skips
    /// when nothing is up next (the prefetch task is left nil).
    private func prefetchNextTrackLyrics() {
        guard let lyricsResolver else { return }
        let nextIndex = index + 1
        guard queue.indices.contains(nextIndex) else { return }
        let nextTrack = queue[nextIndex]
        lyricsPrefetchTask = Task { @MainActor in
            _ = await lyricsResolver(nextTrack, .prefetch)
        }
    }

    /// Walks the rest of the queue past the immediate-next track and warms
    /// the lyrics cache for each, one at a time with a small spacing between
    /// requests. By the time the user reaches the middle of an album every
    /// track ahead is already a cache hit, so the panel snaps in on advance
    /// with no spinner.
    ///
    /// The resolver itself short-circuits on L1/L2/L3 cache hits, so a
    /// re-played album costs essentially nothing — the loop blasts through
    /// the queue in milliseconds. Only previously-unseen tracks actually
    /// touch the network, and even those are paced to be a polite trickle
    /// rather than a burst. The sweep is also capped to the next
    /// `maxBulkPrefetch` tracks so a thousand-track playlist doesn't schedule
    /// an unbounded crawl — anything past the cap is warmed lazily as the user
    /// advances and this sweep re-runs from the new position.
    private func prefetchRestOfQueueLyrics() {
        guard let lyricsResolver else { return }
        let startIndex = index + 2 // immediate-next is handled separately
        guard startIndex < queue.count else { return }
        let endIndex = min(startIndex + Self.maxBulkPrefetch, queue.count)
        let upcoming = Array(queue[startIndex..<endIndex])
        lyricsBulkPrefetchTask = Task { @MainActor [weak self] in
            for track in upcoming {
                guard !Task.isCancelled else { return }
                _ = await lyricsResolver(track, .prefetch)
                guard !Task.isCancelled else { return }
                // Bail if the playback context changed under us (skip, stop,
                // new album) — `loadLyrics` will have replaced this task.
                guard let self, self.queue.contains(where: { $0.id == track.id }) else { return }
                try? await Task.sleep(for: Self.bulkPrefetchSpacing)
            }
        }
    }

    private func refreshDuration() async {
        guard let item = player.currentItem else { return }
        let deadline = Date().addingTimeInterval(5)
        while item.status != .readyToPlay, Date() < deadline {
            if item.status == .failed { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let seconds = item.duration.seconds
        if seconds.isFinite, seconds > 0 {
            duration = seconds
        }
    }

    // MARK: Play reporting

    /// Fires a single best-effort report for `track` to its owning server. All
    /// state bookkeeping (which track is live, throttle timestamp) is handled by
    /// the callers below; this just logs and dispatches. The network report runs
    /// on a detached task so a slow server never blocks the controller. Once a
    /// `.stop` has been delivered — the point where the server records the play —
    /// we bump `recentPlayReportToken` so the landing rail can refresh.
    private func fireReport(_ event: PlaybackEvent, for track: MusicTrack, position: TimeInterval) {
        // Either sink (the provider reporter or the global Last.fm observer) is
        // enough to warrant dispatching; Last.fm can be connected even when the
        // active provider isn't a reporting `MediaProvider`.
        guard reporter != nil || scrobbleObserver != nil else { return }
        // Prefer the duration the engine actually learned from the AVPlayerItem —
        // some servers omit it from track metadata, and the Plex scrobble decision
        // needs a real length (a missing/zero duration would suppress it entirely).
        let resolvedDuration = duration > 0 ? duration : (track.duration ?? 0)
        MusicReportDiagnostics.emit(
            "dispatch \(event.rawValue) pos=\(Int(position))s id=\(track.id) '\(track.title)'"
        )
        Task {
            await reporter?(track, event, position, resolvedDuration)
            await scrobbleObserver?(track, event, position, resolvedDuration)
            if event == .stop { self.recentPlayReportToken &+= 1 }
        }
    }

    /// Opens a server-side now-playing session for the freshly-started `track`.
    /// Records it as the live/reported track so subsequent progress/pause/stop
    /// reports target the right item.
    private func reportStart(_ track: MusicTrack) {
        reportedTrack = track
        lastProgressReportAt = Date()
        fireReport(.start, for: track, position: 0)
    }

    /// Closes the live track's now-playing session at `position` (marking it
    /// played when the position is at/near its duration). No-op when there's no
    /// live reported track, so it's safe to call speculatively before a hand-off.
    private func reportStopIfNeeded(position: TimeInterval) {
        guard let track = reportedTrack else { return }
        reportedTrack = nil
        lastProgressReportAt = nil
        fireReport(.stop, for: track, position: position)
    }

    /// Reports a pause/unpause for the live track (Jellyfin: an `IsPaused`
    /// progress ping; Plex: a `paused`/`playing` timeline). No-op when nothing is
    /// reported, which keeps the end-of-queue auto-`pause()` from emitting a
    /// spurious pause after `handleItemDidEnd` already reported the stop.
    private func reportPauseState(paused: Bool) {
        guard let track = reportedTrack else { return }
        if !paused { lastProgressReportAt = Date() }
        fireReport(paused ? .pause : .unpause, for: track, position: currentTime)
    }

    /// Emits a throttled `.progress` heartbeat off the 4×/sec time observer —
    /// at most once per `progressReportInterval` — so the server's position stays
    /// fresh and Plex can auto-scrobble as the timeline nears the end. Only fires
    /// while actually playing a live reported track.
    private func maybeReportProgress() {
        guard isPlaying, let track = reportedTrack else { return }
        let now = Date()
        if let last = lastProgressReportAt,
           now.timeIntervalSince(last) < Self.progressReportInterval {
            return
        }
        lastProgressReportAt = now
        fireReport(.progress, for: track, position: currentTime)
    }

    // MARK: Observers

    private func installTimeObserver() {
        // Sample 4×/sec so synced-lyric highlighting tracks the music closely.
        // A 1s interval makes the active line trail the vocal by up to a second.
        let interval = CMTime(value: 1, timescale: 4)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // The callback is delivered on the main queue; hop to the main actor
            // to satisfy strict concurrency.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Log timeControlStatus TRANSITIONS (not the 4×/sec noise). A
                // playing→waiting→paused slide with no user pause is the
                // fingerprint of an AirPlay route drop, so capture it always —
                // even during the debounced-skip pending window below.
                let tc = self.player.timeControlStatus
                if tc != self.lastLoggedTimeControl {
                    self.lastLoggedTimeControl = tc
                    self.diag("player", "timeControl→[\(self.playerStateSummary())] route=\(self.routeSummary())")
                }
                // While a debounced skip is pending the outgoing track is still
                // playing, but the UI already shows the target track — so don't
                // let the old item's position drive the scrubber; keep it at 0.
                guard !self.startPending else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
                if self.duration == 0, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
                self.maybeReportProgress()
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleItemDidEnd()
            }
        }
    }

    // MARK: Audio session

    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        #if canImport(AVFoundation) && !os(macOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // `.longFormAudio` route-sharing policy marks this as a music/
            // long-form audio app, giving it the same Now Playing treatment as
            // Apple Music/Podcasts. Without it tvOS treats the audio as generic
            // and may not surface the Control Center Now Playing card.
            do {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            } catch {
                // Fall back to plain `.playback` if the policy variant is rejected.
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
        } catch {
            // Non-fatal: audio still plays in the foreground without the session.
        }
        #endif
    }

    /// Registers the AirPlay recovery safety net. A track transition can make the
    /// system momentarily tear down or reconfigure the route to an AirPlay 2
    /// speaker; when that happens `AVPlayer` auto-pauses and does NOT auto-resume,
    /// leaving the speaker silent until it's physically reconnected. These
    /// observers detect the disruption and, when we still intend to be playing,
    /// re-activate the session and resume so playback recovers on its own. The
    /// treadmill (pre-enqueuing) is the primary fix that prevents the teardown;
    /// this is defence-in-depth for the cases it can't preroll (arbitrary jumps).
    private func installRouteRecoveryObservers() {
        #if canImport(AVFoundation) && !os(macOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // `routeChangeNotification` is posted on a secondary thread; delivering the
        // block on `.main` lets us safely touch main-actor state.
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
        #endif
    }

    #if canImport(AVFoundation) && !os(macOS)
    private func handleRouteChange(_ note: Notification) {
        // Log every route change with its reason + the route before/after. This is
        // the single most important signal for the AirPlay skip bug: we want to see
        // the exact notification sequence a skip produces on the HomePod.
        let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 999
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        let reasonName: String
        switch reason {
        case .unknown: reasonName = "unknown"
        case .newDeviceAvailable: reasonName = "newDeviceAvailable"
        case .oldDeviceUnavailable: reasonName = "oldDeviceUnavailable"
        case .categoryChange: reasonName = "categoryChange"
        case .override: reasonName = "override"
        case .wakeFromSleep: reasonName = "wakeFromSleep"
        case .noSuitableRouteForCategory: reasonName = "noSuitableRouteForCategory"
        case .routeConfigurationChange: reasonName = "routeConfigurationChange"
        case .none: reasonName = "raw(\(reasonRaw))"
        @unknown default: reasonName = "unknown(\(reasonRaw))"
        }
        var line = "reason=\(reasonName) now=\(routeSummary())"
        if let prev = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription {
            let prevOuts = prev.outputs.map { "\($0.portType.rawValue):\"\($0.portName)\"" }.joined(separator: " + ")
            line += " prev=\(prevOuts.isEmpty ? "<none>" : prevOuts)"
        }
        line += " state=[\(playerStateSummary())]"
        diag("route", line)
        // IMPORTANT: We deliberately take NO recovery action here — reacting to
        // route changes (forcing AVAudioSession.setActive(true) on
        // `.routeConfigurationChange`) is what was intermittently BREAKING AirPlay
        // 2 skips. `.routeConfigurationChange` is a benign notification an AirPlay
        // 2 device fires *during* a normal track transition; re-activating the
        // session mid-reconfiguration races the system's own route management and
        // tears the speaker down. A genuine route loss instead arrives as an
        // AVAudioSession INTERRUPTION (tvOS 17+), which `handleInterruption`
        // recovers from at the documented-safe moment. So: log only, act never.
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            // System interrupted us (on tvOS 17+ this includes a route disconnect).
            // AVPlayer has already paused; nothing to do until it ends.
            diag("interrupt", "BEGAN route=\(routeSummary()) isPlaying=\(isPlaying) state=[\(playerStateSummary())]")
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            diag("interrupt", "ENDED shouldResume=\(options.contains(.shouldResume)) route=\(routeSummary()) isPlaying=\(isPlaying) state=[\(playerStateSummary())]")
            // Only resume when the system says it's safe AND we still intend to
            // play (a user pause leaves `isPlaying` false, so we stay put).
            if options.contains(.shouldResume) {
                attemptPlaybackRecovery()
            }
        @unknown default:
            break
        }
    }

    /// Re-activates the audio session and resumes the player when we still intend
    /// to be playing but the render pipeline parked after a route disruption.
    private func attemptPlaybackRecovery() {
        guard hasActivePlayback, isPlaying else {
            diag("recover", "skipped (hasActivePlayback=\(hasActivePlayback) isPlaying=\(isPlaying))")
            return
        }
        diag("recover", "attempting: setActive(true) + play route=\(routeSummary()) state=[\(playerStateSummary())]")
        try? AVAudioSession.sharedInstance().setActive(true)
        if player.timeControlStatus != .playing {
            player.play()
        }
    }
    #endif


    // MARK: Now Playing + remote commands

    #if canImport(MediaPlayer)
    /// Publishes the current track to `MPNowPlayingInfoCenter`, which drives the
    /// tvOS Control Center Now Playing card (and the screensaver/remote). The
    /// app becomes the system Now Playing app by having an active `.playback`
    /// audio session, registered `MPRemoteCommandCenter` handlers, and a
    /// non-nil `nowPlayingInfo` while audio plays. Assigning `nowPlayingInfo`
    /// replaces the whole dictionary, so we rebuild it (re-attaching artwork)
    /// on every state change.
    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = track.artistName { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let currentArtwork { info[MPMediaItemPropertyArtwork] = currentArtwork }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
    #endif

    private func enableRemoteCommands() {
        #if canImport(MediaPlayer)
        guard !remoteCommandsActive else { return }
        remoteCommandsActive = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        // tvOS delivers remote-command handlers on a background queue, but these
        // actions mutate main-actor `@Observable` state and the player, so hop
        // to the main actor instead of touching it off-thread.
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in await self?.seek(to: position) }
            return .success
        }
        #endif
    }

    /// Removes our handlers and clears Now Playing so the system no longer
    /// routes the Siri Remote's Play/Pause button to music — letting the video
    /// player receive it again.
    private func disableRemoteCommands() {
        #if canImport(MediaPlayer)
        guard remoteCommandsActive else { return }
        remoteCommandsActive = false
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        currentArtwork = nil
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = nil
        info.playbackState = .stopped
        #endif
    }

    private func loadArtwork(for track: MusicTrack) {
        #if canImport(MediaPlayer) && canImport(UIKit)
        artworkLoadTask?.cancel()
        guard let url = track.artworkURL else { return }
        if let cached = ArtworkImageCache.shared.cachedImage(for: url) {
            currentArtwork = Self.makeArtwork(from: cached)
            updateNowPlayingInfo()
            return
        }
        let trackID = track.id
        artworkLoadTask = Task { [weak self] in
            guard let image = await ArtworkImageCache.shared.image(for: url) else { return }
            let artwork = Self.makeArtwork(from: image)
            await MainActor.run {
                guard let self, self.currentTrack?.id == trackID else { return }
                self.currentArtwork = artwork
                self.updateNowPlayingInfo()
            }
        }
        #endif
    }

    #if canImport(MediaPlayer) && canImport(UIKit)
    /// Returns the track's artwork for the initial Now Playing publish, serving a
    /// cached copy instantly and otherwise waiting only briefly for the download
    /// so the system banner can include it without stalling the card.
    private func bannerArtworkImage(_ url: URL) async -> UIImage? {
        if let cached = ArtworkImageCache.shared.cachedImage(for: url) { return cached }
        return await withTaskGroup(of: UIImage?.self) { group in
            group.addTask { await ArtworkImageCache.shared.image(for: url) }
            group.addTask { try? await Task.sleep(nanoseconds: 700_000_000); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// Wraps a decoded image as `MPMediaItemArtwork`, rendering to whatever size
    /// the system requests (returning a mismatched/original-size image makes the
    /// Now Playing surfaces silently drop the artwork).
    private nonisolated static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { size in
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
    #endif
}
#endif
