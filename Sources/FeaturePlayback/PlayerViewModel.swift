#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking

/// Owns the `AVPlayer` for a single playback session.
///
/// Responsibilities:
///  * resolve a `PlaybackRequest` via the provider;
///  * seek to the saved resume position on start;
///  * report progress to the server periodically + on pause/stop so resume
///    points stay in sync (Phase 1 requirement);
///  * surface a graceful error state instead of a blank screen.
@MainActor
@Observable
public final class PlayerViewModel {
    public enum Phase: Equatable {
        case loading
        case ready
        case failed(AppError)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var player: AVPlayer?

    private let provider: any MediaProvider
    private let itemID: String
    private let captionSettings: CaptionSettings
    /// Explicit start position (seconds) that overrides the provider's resume
    /// point when set. `nil` keeps the default behaviour (derive from the
    /// `PlaybackRequest`); `0` forces "start over"; a positive value resumes.
    private let startPositionOverride: TimeInterval?
    private var request: PlaybackRequest?
    private var timeObserver: Any?
    private let reportInterval: TimeInterval = 10
    private var lastReportedSecond: Int = -1
    private var subtitleDownloadTask: Task<Void, Never>?
    /// Retains the resource-loader delegate that serves injected subtitle
    /// playlists; `AVAssetResourceLoader` holds it only weakly.
    private var subtitleLoader: SubtitleInjectingResourceLoader?

    /// Furthest position (seconds) we've observed, so a transcode-fallback retry
    /// can resume where the failed direct-play attempt left the viewer.
    private var lastKnownPosition: TimeInterval = 0
    /// Guards the automatic transcode fallback so it only ever fires once — a
    /// second failure surfaces the error instead of looping.
    private var hasAttemptedTranscodeFallback = false
    private var fallbackMonitorTask: Task<Void, Never>?
    private var audioSessionConfigured = false
    #if !os(macOS)
    private var routeChangeObserver: NSObjectProtocol?
    #endif

    public init(
        provider: any MediaProvider,
        itemID: String,
        captionSettings: CaptionSettings = .default,
        startPosition: TimeInterval? = nil
    ) {
        self.provider = provider
        self.itemID = itemID
        self.captionSettings = captionSettings
        self.startPositionOverride = startPosition
    }

    /// Loads stream info, configures the player, and seeks to resume.
    public func load() async {
        await startPlayback(forceTranscode: false, resumeOverride: nil)
    }

    /// Resolves a stream and brings up the player. `forceTranscode` asks the
    /// provider to bypass direct play (used by the automatic fallback); when set,
    /// `resumeOverride` carries the position the failed attempt reached so the
    /// retry resumes there instead of the provider's stale resume point.
    private func startPlayback(forceTranscode: Bool, resumeOverride: TimeInterval?) async {
        phase = .loading
        configureAudioSession()
        do {
            let request = try await provider.playbackInfo(for: itemID, forceTranscode: forceTranscode)
            self.request = request

            let asset = makeAsset(for: request)
            let item = AVPlayerItem(asset: asset)
            // Apply in-app caption styling overrides if the user set any.
            item.textStyleRules = captionSettings.textStyleRules()

            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true
            self.player = player

            // An explicit override wins over the provider's resume point so the
            // caller can force "start over" (0) or resume from a chosen second.
            let startPosition = resumeOverride ?? startPositionOverride ?? request.startPosition
            lastKnownPosition = max(lastKnownPosition, startPosition)
            if startPosition > 1 {
                await seekWhenReady(player: player, to: startPosition)
            }

            // Watch for a direct-play item that can't actually be decoded so we
            // can transparently re-resolve via a server transcode.
            monitorForTranscodeFallback(item: item)

            installTimeObserver(on: player)
            phase = .ready
            player.play()
            await report(event: .start, isPaused: false)

            // Best-effort, never blocking play(): pick the default subtitle for
            // the user's mode/language, and (if enabled) fetch a missing one.
            await applyDefaultSubtitleSelection(for: item)
            startAutoSubtitleDownloadIfNeeded(request: request)
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            phase = .failed(.unknown(""))
        }
    }

    // MARK: - Asset construction

    /// Builds the asset to play. When the server is direct-playing the original
    /// file (not transcoding) and the item has text subtitles the player would
    /// otherwise never see, wrap the stream in a synthesized HLS playlist that
    /// adds those subtitles as selectable renditions. Otherwise play the stream
    /// URL directly (transcoded HLS already carries subtitles in its manifest).
    private func makeAsset(for request: PlaybackRequest) -> AVURLAsset {
        subtitleLoader = nil
        guard !request.isTranscoding else {
            return AVURLAsset(url: request.streamURL)
        }
        let injectables: [InjectableSubtitle] = request.subtitleTracks.compactMap { track in
            guard track.kind == .subtitle, let url = track.deliveryURL else { return nil }
            return InjectableSubtitle(
                index: track.id,
                name: track.displayTitle,
                languageTag: track.language,
                isDefault: track.isDefault,
                isForced: track.isForced,
                sourceURL: url
            )
        }
        guard !injectables.isEmpty, let duration = request.item.runtime, duration > 0 else {
            return AVURLAsset(url: request.streamURL)
        }
        let composer = SubtitleHLSComposer(
            videoURL: request.streamURL,
            durationSeconds: duration,
            subtitles: injectables
        )
        let loader = SubtitleInjectingResourceLoader(composer: composer)
        subtitleLoader = loader
        return loader.makeAsset()
    }

    // MARK: - Audio session

    /// Best-effort: configure the shared audio session for video playback so
    /// multichannel/Atmos passthrough and spatialization route correctly. Never
    /// blocks or fails playback — any error is swallowed.
    private func configureAudioSession() {
        #if !os(macOS)
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            PlozzLog.playback.debug("Audio session configuration failed (non-fatal)")
        }
        observeAudioRouteChanges(session)
        #endif
    }

    #if !os(macOS)
    /// Re-asserts the active session when the audio route changes (e.g. an AVR or
    /// TV is switched mid-playback) so multichannel routing follows the new
    /// output. Best-effort and crash-safe.
    private func observeAudioRouteChanges(_ session: AVAudioSession) {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                PlozzLog.playback.debug("Audio route changed; re-activated session")
            }
        }
    }
    #endif

    // MARK: - Transcode fallback

    /// Polls the new player item's status; if it fails to load on a direct-play
    /// stream, re-resolves playback forcing a server transcode and resumes from
    /// the last known position. Fires at most once and never for an item that was
    /// already transcoding.
    private func monitorForTranscodeFallback(item: AVPlayerItem) {
        fallbackMonitorTask?.cancel()
        fallbackMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch item.status {
                case .failed:
                    await self.handleDirectPlayFailure()
                    return
                case .readyToPlay:
                    return
                default:
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    private func handleDirectPlayFailure() async {
        guard let request, !request.isTranscoding, !hasAttemptedTranscodeFallback else {
            // Already transcoding, already retried, or no request: surface the
            // error rather than looping.
            phase = .failed(currentPlayerError())
            return
        }
        hasAttemptedTranscodeFallback = true
        let resumeFrom = max(lastKnownPosition, currentPositionSeconds())
        PlozzLog.playback.info("Direct play failed; retrying with server transcode")
        teardownPlayerForRetry()
        await startPlayback(forceTranscode: true, resumeOverride: resumeFrom > 1 ? resumeFrom : nil)
    }

    /// Tears the failed player down without reporting a stop — playback is being
    /// retried under a new stream, not ended.
    private func teardownPlayerForRetry() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        lastReportedSecond = -1
    }

    private func currentPlayerError() -> AppError {
        if player?.currentItem?.error != nil {
            return .invalidResponse
        }
        return .unknown("")
    }

    /// The player's current position in seconds, or `0` when unknown/non-finite.
    private func currentPositionSeconds() -> TimeInterval {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    /// Seeks to `seconds`, clamped into the stream's seekable range. Tolerances
    /// are non-zero so far seeks resolve to the nearest keyframe instead of
    /// stalling on an exact-frame seek (which can fail on transcoded HLS).
    public func seek(to seconds: TimeInterval) async {
        guard let player else { return }
        await seek(player: player, to: seconds)
    }

    /// Waits (briefly) for the player item to become ready before seeking. A
    /// resume seek issued before the asset is ready — common for far positions —
    /// is silently dropped by AVPlayer, leaving playback at 0.
    private func seekWhenReady(player: AVPlayer, to seconds: TimeInterval) async {
        guard let item = player.currentItem else { return }
        let deadline = Date().addingTimeInterval(5)
        while item.status != .readyToPlay, Date() < deadline {
            if item.status == .failed { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await seek(player: player, to: seconds)
    }

    private func seek(player: AVPlayer, to seconds: TimeInterval) async {
        let target = clampToSeekableRange(seconds, item: player.currentItem)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        // Allow a small tolerance: exact (.zero) seeks can stall or fail on
        // transcoded HLS, which is exactly the far-seek failure we're fixing.
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        await player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    /// Clamps a target time into the item's seekable range when one is known, so
    /// a seek past the currently-available range doesn't error out.
    private func clampToSeekableRange(_ seconds: TimeInterval, item: AVPlayerItem?) -> TimeInterval {
        guard let ranges = item?.seekableTimeRanges, !ranges.isEmpty else { return max(0, seconds) }
        var lower = TimeInterval.greatestFiniteMagnitude
        var upper = 0.0
        for value in ranges {
            let range = value.timeRangeValue
            lower = min(lower, range.start.seconds)
            upper = max(upper, (range.start + range.duration).seconds)
        }
        guard upper > 0 else { return max(0, seconds) }
        return min(max(seconds, lower), upper)
    }

    private func installTimeObserver(on player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if time.seconds.isFinite { self.lastKnownPosition = max(0, time.seconds) }
            let seconds = Int(time.seconds)
            guard seconds != self.lastReportedSecond, seconds % Int(self.reportInterval) == 0 else { return }
            self.lastReportedSecond = seconds
            Task { await self.report(event: .progress, isPaused: false) }
        }
    }

    /// Reports the current position. Best-effort: a failed report must never
    /// interrupt playback, so errors are swallowed (and never logged with data).
    private func report(event: PlaybackEvent, isPaused: Bool) async {
        guard let player, let request else { return }
        let progress = PlaybackProgress(
            itemID: itemID,
            playSessionID: request.playSessionID,
            positionSeconds: player.currentTime().seconds,
            isPaused: isPaused
        )
        do {
            try await provider.reportPlayback(progress, event: event)
        } catch {
            PlozzLog.playback.debug("Progress report failed (non-fatal)")
        }
    }

    public func setPaused(_ paused: Bool) {
        guard let player else { return }
        if paused { player.pause() } else { player.play() }
        Task { await report(event: paused ? .pause : .unpause, isPaused: paused) }
    }

    /// Call when leaving playback: report a final stop so the server records the
    /// resume point, then tear the player down.
    public func stop() async {
        await report(event: .stop, isPaused: true)
        subtitleDownloadTask?.cancel()
        subtitleDownloadTask = nil
        fallbackMonitorTask?.cancel()
        fallbackMonitorTask = nil
        subtitleLoader = nil
        #if !os(macOS)
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
        #endif
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    /// A stable identity for the active player instance, so views can restart
    /// player-bound work (e.g. the diagnostics sampler) when the transcode
    /// fallback swaps in a new player.
    public var playerInstanceID: ObjectIdentifier? {
        player.map(ObjectIdentifier.init)
    }

    public var availableSubtitleTracks: [MediaTrack] { request?.subtitleTracks ?? [] }
    public var availableAudioTracks: [MediaTrack] { request?.audioTracks ?? [] }

    /// Whether the active stream is being transcoded by the server (vs direct
    /// play). Read by the playback diagnostics overlay.
    public var isTranscoding: Bool { request?.isTranscoding ?? false }

    /// Provider source facts (codec/HDR/channels/…) for the playing item, used
    /// to populate the playback diagnostics overlay.
    public var sourceMetadata: MediaSourceMetadata? { request?.sourceMetadata }

    // MARK: - Subtitle selection & auto-download

    /// Chooses the default legible (subtitle) option on the player item to honour
    /// the user's subtitle mode + preferred language, using the asset's own
    /// AVMediaSelectionGroup. Best-effort: any failure leaves AVPlayer's default
    /// selection untouched and never affects playback.
    private func applyDefaultSubtitleSelection(for item: AVPlayerItem) async {
        guard let group = await legibleGroup(for: item.asset) else { return }

        let options = group.options
        let candidates: [SubtitleCandidate] = options.enumerated().map { index, option in
            SubtitleCandidate(
                id: index,
                languageCode: option.extendedLanguageTag ?? option.locale?.identifier,
                isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                isDefault: group.defaultOption == option
            )
        }

        let decision = SubtitleSelector.decide(
            candidates: candidates,
            mode: captionSettings.subtitleMode,
            preferredLanguage: captionSettings.resolvedPreferredLanguage
        )

        switch decision {
        case .none:
            item.select(nil, in: group)
        case .select(let id):
            guard options.indices.contains(id) else { return }
            item.select(options[id], in: group)
        }
    }

    private func legibleGroup(for asset: AVAsset) async -> AVMediaSelectionGroup? {
        try? await asset.loadMediaSelectionGroup(for: .legible)
    }

    /// If auto-download is enabled and the item lacks a suitable subtitle in the
    /// preferred language, kicks off a detached background search+download so the
    /// server fetches one. Never blocks or affects the current playback session.
    private func startAutoSubtitleDownloadIfNeeded(request: PlaybackRequest) {
        guard captionSettings.autoDownloadSubtitles else { return }
        let language = captionSettings.resolvedPreferredLanguage
        guard !request.subtitleTracks.hasSuitableSubtitle(forLanguage: language) else { return }
        guard let language, !language.isEmpty else { return }

        let provider = self.provider
        let itemID = self.itemID
        let mode = captionSettings.subtitleMode
        subtitleDownloadTask = Task.detached(priority: .background) {
            do {
                let results = try await provider.remoteSubtitleSearch(itemID: itemID, language: language)
                guard let best = results.bestMatch(forLanguage: language, mode: mode), !best.id.isEmpty else {
                    return
                }
                try await provider.downloadRemoteSubtitle(itemID: itemID, subtitleID: best.id)
                PlozzLog.playback.info("Auto-downloaded subtitle for item")
            } catch {
                PlozzLog.playback.debug("Auto subtitle download failed (non-fatal)")
            }
        }
    }
}

#endif
