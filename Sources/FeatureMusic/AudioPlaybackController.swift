#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
#if canImport(MediaPlayer)
import MediaPlayer
#endif

// `MediaPlayer` transitively imports AudioToolbox, which declares a C `MusicTrack`
// type. Disambiguate so `MusicTrack` here always means our domain model.
public typealias MusicTrack = CoreModels.MusicTrack

/// The app-scoped audio playback engine — **independent** of the video
/// `PlayerViewModel`, which stays full-screen and untouched.
///
/// Owns an `AVQueuePlayer` and a manually-managed track queue so it can resolve
/// each track's stream URL on demand, support shuffle/repeat, and drive
/// next/previous. It is created once and injected into the environment, so the
/// mini-player and the Now Playing screen observe the *same* instance.
///
/// tvOS background audio (the part the video flow never does):
///  * configures `AVAudioSession` `.playback` + `setActive(true)` so audio keeps
///    playing while the user browses other screens or the screensaver starts;
///  * publishes `MPNowPlayingInfoCenter` (title/artist/album, artwork, duration,
///    elapsed) for the system Now Playing surface;
///  * wires `MPRemoteCommandCenter` (play/pause/toggle/next/previous/seek) so the
///    Siri Remote transport controls drive the queue.
@MainActor
@Observable
public final class AudioPlaybackController {
    public enum RepeatMode: Sendable, CaseIterable {
        case off, all, one
    }

    /// Closure that resolves a playable stream URL for a track (provider-backed),
    /// allowing the engine to stay decoupled from any concrete provider.
    public typealias StreamURLResolver = @MainActor (MusicTrack) async -> URL?

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
    /// The unshuffled queue, so toggling shuffle off restores original order.
    private var orderedQueue: [MusicTrack] = []
    private var playSessionID: String?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var sessionConfigured = false
    private var remoteCommandsActive = false
    #if canImport(MediaPlayer)
    /// Registers this app as the system Now Playing app. On tvOS, populating
    /// `MPNowPlayingInfoCenter` alone does NOT surface the Control Center Now
    /// Playing card — the app must own an *active* `MPNowPlayingSession` bound to
    /// the `AVPlayer`. Created lazily so we only claim Now Playing once music
    /// actually starts (see `enableRemoteCommands`).
    private var nowPlayingSession: MPNowPlayingSession?
    #endif
    private var artworkLoadTask: Task<Void, Never>?

    public init() {
        player.actionAtItemEnd = .none
        installTimeObserver()
    }

    // MARK: Public API

    /// Starts playing `tracks` from `startIndex`. `resolveStreamURL` maps each
    /// track to its playable URL (the owning provider's audio stream), called
    /// lazily as the queue advances so we never resolve a whole album up front.
    public func play(
        tracks: [MusicTrack],
        startIndex: Int,
        playSessionID: String? = nil,
        resolveStreamURL: @escaping StreamURLResolver
    ) {
        guard !tracks.isEmpty else { return }
        self.resolver = resolveStreamURL
        self.playSessionID = playSessionID
        self.orderedQueue = tracks
        self.isShuffled = false
        self.queue = tracks
        self.index = min(max(startIndex, 0), tracks.count - 1)
        configureSessionIfNeeded()
        Task { await startCurrent() }
    }

    /// Plays the whole list shuffled, starting on a random track.
    public func playShuffled(
        tracks: [MusicTrack],
        playSessionID: String? = nil,
        resolveStreamURL: @escaping StreamURLResolver
    ) {
        guard !tracks.isEmpty else { return }
        self.resolver = resolveStreamURL
        self.playSessionID = playSessionID
        self.orderedQueue = tracks
        self.isShuffled = true
        self.queue = tracks.shuffled()
        self.index = 0
        configureSessionIfNeeded()
        Task { await startCurrent() }
    }

    public func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    public func resume() {
        guard hasActivePlayback else { return }
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackRate()
    }

    public func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackRate()
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
        Task { await startCurrent() }
    }

    public func seek(to seconds: TimeInterval) async {
        let target = max(0, seconds)
        await player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = target
        updateNowPlayingElapsed()
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
    }

    /// Stops playback and clears the queue — hides the mini-player.
    public func stop() {
        player.pause()
        player.removeAllItems()
        isPlaying = false
        queue = []
        orderedQueue = []
        index = 0
        currentTime = 0
        duration = 0
        clearNowPlaying()
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
    }

    // MARK: Queue advancement

    private func advance(by offset: Int, userInitiated: Bool) {
        guard hasActivePlayback else { return }
        let next = index + offset
        if next < 0 {
            index = 0
            Task { await startCurrent() }
            return
        }
        if next >= queue.count {
            // Past the end: wrap on repeat-all, otherwise stop at the last track.
            if repeatMode == .all {
                index = 0
                Task { await startCurrent() }
            } else if userInitiated {
                index = queue.count - 1
                Task { await startCurrent() }
            } else {
                pause()
            }
            return
        }
        index = next
        Task { await startCurrent() }
    }

    /// Called when the current item finishes on its own.
    private func handleItemDidEnd() {
        if repeatMode == .one {
            Task { await startCurrent() }
        } else {
            advance(by: 1, userInitiated: false)
        }
    }

    private func startCurrent() async {
        guard let track = currentTrack, let resolver else { return }
        guard let url = await resolver(track) else { return }
        // Claim the system remote/Now Playing controls only once music is
        // actually playing. Registering them eagerly (e.g. at app launch) makes
        // tvOS route the Siri Remote's Play/Pause button to the command center
        // instead of delivering it to the foreground view, which silently breaks
        // the video player's own Play/Pause handling.
        enableRemoteCommands()
        let item = AVPlayerItem(url: url)
        player.removeAllItems()
        player.insert(item, after: nil)
        observeEnd(of: item)
        player.play()
        isPlaying = true
        currentTime = 0
        duration = track.duration ?? 0
        updateNowPlaying(for: track)
        await refreshDuration()
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
            updateNowPlayingElapsed()
        }
    }

    // MARK: Observers

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // The callback is delivered on the main queue; hop to the main actor
            // to satisfy strict concurrency.
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
                if self.duration == 0, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.duration = d
                }
                self.updateNowPlayingElapsed()
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
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            // Non-fatal: audio still plays in the foreground without the session.
        }
        #endif
    }

    // MARK: Now Playing + remote commands

    #if canImport(MediaPlayer)
    /// Creates the Now Playing session on first use. Routing info/commands
    /// through the session (instead of the `MPNowPlayingInfoCenter.default()` /
    /// `MPRemoteCommandCenter.shared()` singletons) is what actually registers us
    /// as the active Now Playing app on tvOS, so the Control Center card appears.
    @discardableResult
    private func ensureNowPlayingSession() -> MPNowPlayingSession {
        if let nowPlayingSession { return nowPlayingSession }
        let session = MPNowPlayingSession(players: [player])
        // We publish provider-supplied title/artist/artwork ourselves, so keep
        // automatic publishing off and drive the session's info center directly.
        session.automaticallyPublishesNowPlayingInfo = false
        nowPlayingSession = session
        return session
    }
    #endif

    private func enableRemoteCommands() {
        #if canImport(MediaPlayer)
        let session = ensureNowPlayingSession()
        // (Re)assert ourselves as the active Now Playing app whenever playback
        // (re)starts — idempotent if we're already active.
        session.becomeActiveIfPossible(completion: nil)
        guard !remoteCommandsActive else { return }
        remoteCommandsActive = true
        let center = session.remoteCommandCenter
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.resume(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.next(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.previous(); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { await self.seek(to: event.positionTime) }
            return .success
        }
        #endif
    }

    /// Removes our handlers and tears down the Now Playing session so the system
    /// no longer routes the Siri Remote's Play/Pause button to music — letting
    /// the video player receive it again.
    private func disableRemoteCommands() {
        #if canImport(MediaPlayer)
        guard remoteCommandsActive else { return }
        remoteCommandsActive = false
        if let center = nowPlayingSession?.remoteCommandCenter {
            center.playCommand.removeTarget(nil)
            center.pauseCommand.removeTarget(nil)
            center.togglePlayPauseCommand.removeTarget(nil)
            center.nextTrackCommand.removeTarget(nil)
            center.previousTrackCommand.removeTarget(nil)
            center.changePlaybackPositionCommand.removeTarget(nil)
        }
        nowPlayingSession = nil
        #endif
    }

    private func updateNowPlaying(for track: MusicTrack) {
        #if canImport(MediaPlayer)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artist = track.artistName { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = track.duration, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        let center = ensureNowPlayingSession().nowPlayingInfoCenter
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        loadArtwork(for: track)
        #endif
    }

    private func updateNowPlayingElapsed() {
        #if canImport(MediaPlayer)
        guard let center = nowPlayingSession?.nowPlayingInfoCenter,
              var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
        #endif
    }

    /// On tvOS (and macOS) the Now Playing surface only appears when the app
    /// reports its `playbackState`; unlike iOS, tvOS does NOT infer it from the
    /// audio session. Drive it on the session's info center on every play/pause.
    private func updateNowPlayingPlaybackRate() {
        #if canImport(MediaPlayer)
        guard let center = nowPlayingSession?.nowPlayingInfoCenter,
              var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        #endif
    }

    private func clearNowPlaying() {
        #if canImport(MediaPlayer)
        if let center = nowPlayingSession?.nowPlayingInfoCenter {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
        #endif
    }

    private func loadArtwork(for track: MusicTrack) {
        #if canImport(MediaPlayer) && canImport(UIKit)
        artworkLoadTask?.cancel()
        guard let url = track.artworkURL else { return }
        let trackID = track.id
        artworkLoadTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                guard let self, self.currentTrack?.id == trackID,
                      let center = self.nowPlayingSession?.nowPlayingInfoCenter else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var info = center.nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                center.nowPlayingInfo = info
            }
        }
        #endif
    }
}
#endif
