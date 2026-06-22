#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking
#if canImport(UIKit)
import UIKit
#endif

/// `AVPlayer`-backed implementation of `VideoEngine`.
///
/// This type contains all of the playback mechanics that `PlayerViewModel` used
/// to own directly — `AVURLAsset`/`AVPlayerItem` construction, caption styling,
/// resume seeking, the periodic time observer + report cadence, the
/// `AVAudioSession` configuration + route-change handling, default subtitle
/// selection, and the transcode-fallback *detection* hook — moved essentially
/// verbatim. The orchestration around it (resolving a `PlaybackRequest`,
/// reporting progress, deciding to re-resolve with a server transcode,
/// downloading subtitles) stays in `PlayerViewModel`, which drives this engine
/// through the `VideoEngine` protocol.
@MainActor
@Observable
public final class NativeVideoEngine: VideoEngine {
    // MARK: Observable state

    public private(set) var status: VideoEngineStatus = .idle
    public private(set) var isPaused: Bool = false

    public var currentTime: TimeInterval {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    public var duration: TimeInterval {
        guard let seconds = player?.currentItem?.duration.seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    public private(set) var furthestObservedPosition: TimeInterval = 0

    /// Furthest buffered position across the item's loaded ranges, for the scrub
    /// bar's buffer fill. `0` when unknown.
    public var bufferedPosition: TimeInterval {
        guard let ranges = player?.currentItem?.loadedTimeRanges else { return 0 }
        var end: TimeInterval = 0
        for value in ranges {
            let range = value.timeRangeValue
            let rangeEnd = (range.start + range.duration).seconds
            if rangeEnd.isFinite { end = max(end, rangeEnd) }
        }
        return end
    }

    public var audioTracks: [MediaTrack] { request?.audioTracks ?? [] }
    public var subtitleTracks: [MediaTrack] { request?.subtitleTracks ?? [] }

    // MARK: Orchestration callbacks

    public var onProgress: (@MainActor () -> Void)?
    public var onFailure: (@MainActor (AppError) -> Void)?

    // MARK: Configuration

    /// Caption styling + default-subtitle preferences. The engine applies these
    /// when building the player item and when choosing the default subtitle.
    private let captionSettings: CaptionSettings

    // MARK: Private playback state

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var request: PlaybackRequest?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let reportInterval: TimeInterval = 10
    @ObservationIgnored private var lastReportedSecond: Int = -1
    @ObservationIgnored private var fallbackMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var audioSessionConfigured = false
    /// Retains the resource-loader delegate that serves injected subtitle
    /// playlists; `AVAssetResourceLoader` holds it only weakly.
    @ObservationIgnored private var subtitleLoader: SubtitleInjectingResourceLoader?
    #if !os(macOS)
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    #endif
    #if canImport(UIKit)
    /// A single, stable `AVPlayerLayer`-backed surface fed by whichever
    /// `AVPlayer` is live, so a transcode-fallback swap re-points the existing
    /// surface instead of forcing the SwiftUI layer to rebuild it.
    @ObservationIgnored private var videoOutputView: PlayerLayerView?
    #endif

    public init(captionSettings: CaptionSettings = .default) {
        self.captionSettings = captionSettings
    }

    /// The live `AVPlayer`, exposed for the AVFoundation-specific diagnostics
    /// sampler. Engine-agnostic callers must not depend on this; a future
    /// non-AVFoundation engine simply wouldn't offer it (diagnostics is
    /// best-effort and non-fatal).
    public var underlyingPlayer: AVPlayer? { player }

    // MARK: - Lifecycle

    public func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        status = .loading
        configureAudioSession()
        // Tear down any previous player (e.g. a failed direct-play attempt being
        // retried under a transcode) without reporting a stop.
        teardownPlayer()

        self.request = request

        let asset = makeAsset(for: request)
        let item = AVPlayerItem(asset: asset)
        // Apply in-app caption styling overrides if the user set any.
        item.textStyleRules = captionSettings.textStyleRules()

        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        self.player = player
        #if canImport(UIKit)
        videoOutputView?.player = player
        #endif

        furthestObservedPosition = max(furthestObservedPosition, startPosition)
        if startPosition > 1 {
            await seekWhenReady(player: player, to: startPosition)
        }

        // Watch for a direct-play item that can't actually be decoded so we can
        // transparently re-resolve via a server transcode.
        monitorForTranscodeFallback(item: item)

        installTimeObserver(on: player)
        status = .ready
        isPaused = false
        player.play()

        // Best-effort: pick the default subtitle for the user's mode/language.
        await applyDefaultSubtitleSelection(for: item)
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

    public func play() {
        guard let player else { return }
        player.play()
        isPaused = false
    }

    public func pause() {
        guard let player else { return }
        player.pause()
        isPaused = true
    }

    public func stop() {
        fallbackMonitorTask?.cancel()
        fallbackMonitorTask = nil
        #if !os(macOS)
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
        #endif
        teardownPlayer()
        #if canImport(UIKit)
        videoOutputView?.player = nil
        videoOutputView = nil
        #endif
        status = .idle
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

    // MARK: - Transcode fallback detection

    /// Polls the new player item's status; if it fails to load, notifies the
    /// owner via `onFailure` with the classified error so it can decide whether to
    /// surface it or re-resolve with a server transcode. Fires at most once per
    /// load.
    private func monitorForTranscodeFallback(item: AVPlayerItem) {
        fallbackMonitorTask?.cancel()
        fallbackMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch item.status {
                case .failed:
                    self.onFailure?(self.currentPlayerError())
                    return
                case .readyToPlay:
                    return
                default:
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    private func currentPlayerError() -> AppError {
        if player?.currentItem?.error != nil {
            return .invalidResponse
        }
        return .unknown("")
    }

    /// Tears the current player down without touching the audio-session or
    /// route-change observers. Used both when reloading for a retry and as part
    /// of `stop()`.
    private func teardownPlayer() {
        fallbackMonitorTask?.cancel()
        fallbackMonitorTask = nil
        subtitleLoader = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        lastReportedSecond = -1
    }

    // MARK: - Seeking

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

    // MARK: - Progress cadence

    private func installTimeObserver(on player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if time.seconds.isFinite { self.furthestObservedPosition = max(0, time.seconds) }
            let seconds = Int(time.seconds)
            guard seconds != self.lastReportedSecond, seconds % Int(self.reportInterval) == 0 else { return }
            self.lastReportedSecond = seconds
            self.onProgress?()
        }
    }

    // MARK: - Subtitle / audio track selection

    /// Chooses the default legible (subtitle) option on the player item to honour
    /// the user's subtitle mode + preferred language, using the asset's own
    /// `AVMediaSelectionGroup`. Best-effort: any failure leaves AVPlayer's default
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

    /// Best-effort manual subtitle selection by matching the track's language
    /// against the asset's legible options. Currently the native
    /// `AVPlayerViewController` picker drives subtitle changes, so this is unused
    /// by the UI; it exists so a future custom picker (or non-native engine) can
    /// switch tracks through the `VideoEngine` abstraction.
    public func selectSubtitleTrack(_ track: MediaTrack?) {
        guard let player, let item = player.currentItem else { return }
        Task { [weak self] in
            guard let self, let group = await self.legibleGroup(for: item.asset) else { return }
            self.select(track: track, in: group, on: item)
        }
    }

    /// Best-effort manual audio selection. As with subtitles, the native picker
    /// currently owns audio switching; this rounds out the abstraction.
    public func selectAudioTrack(_ track: MediaTrack?) {
        guard let player, let item = player.currentItem else { return }
        Task { [weak self] in
            guard let self,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
            self.select(track: track, in: group, on: item)
        }
    }

    private func select(track: MediaTrack?, in group: AVMediaSelectionGroup, on item: AVPlayerItem) {
        guard let track, let language = track.language else {
            item.select(nil, in: group)
            return
        }
        let match = group.options.first { option in
            let tag = option.extendedLanguageTag ?? option.locale?.identifier
            return tag?.caseInsensitiveCompare(language) == .orderedSame
        }
        item.select(match, in: group)
    }

    // MARK: - View

    #if canImport(UIKit)
    public func makeVideoOutputView() -> UIView {
        if let existing = videoOutputView { return existing }
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.player = player
        videoOutputView = view
        return view
    }
    #endif
}

#if canImport(UIKit)
/// A bare video surface whose backing layer is an `AVPlayerLayer`. Renders the
/// live stream and nothing else; the shared player overlay sits above it and
/// owns all transport UI and Siri Remote input.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
}
#endif
#endif
