#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking
#if canImport(UIKit)
import UIKit
#endif
#if os(tvOS)
import AVKit
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

    /// Keep the display awake only while the player is genuinely advancing
    /// frames. `timeControlStatus == .playing` is `false` when paused, ended, or
    /// stalled waiting to buffer, so the screensaver/sleep is allowed in exactly
    /// those cases — matching the cross-engine policy.
    public var preventsDisplaySleep: Bool {
        player?.timeControlStatus == .playing
    }

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
    public var onEnded: (@MainActor () -> Void)?
    /// Native tracks are known synchronously and AVPlayer draws its own
    /// subtitles (legible group) / Plozz draws sidecar cues via the VM, so the
    /// native engine never fires either of these. Declared to satisfy the
    /// protocol.
    public var onTracksChanged: (@MainActor () -> Void)?
    public var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    public var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    public var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?

    // MARK: Configuration

    /// Subtitle appearance. The engine applies these style rules when building
    /// the player item, and re-applies them live via ``updateSubtitleStyle(_:)``
    /// when the viewer edits the look mid-playback.
    private var style: SubtitleStyle

    // MARK: Private playback state

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var request: PlaybackRequest?
    @ObservationIgnored private let authenticatedHTTPResolver:
        (any AuthenticatedHTTPResourceResolving)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private let reportInterval: TimeInterval = 10
    @ObservationIgnored private var lastReportedSecond: Int = -1
    @ObservationIgnored private var fallbackMonitorTask: Task<Void, Never>?
    /// Detects an item that decodes audio but renders **no video frames** (e.g.
    /// HEVC AVPlayer can't display) so we can swap to the on-device engine.
    @ObservationIgnored private var missingVideoProbeTask: Task<Void, Never>?
    /// Inspects the real container video format the moment it loads (concurrently
    /// with playback start) so a known AVPlayer-hostile codec can swap instantly
    /// instead of waiting out the no-frames probe.
    @ObservationIgnored private var formatInspectTask: Task<Void, Never>?
    @ObservationIgnored private var audioSessionConfigured = false
    /// Retains the resource-loader delegate that serves injected subtitle
    /// playlists; `AVAssetResourceLoader` holds it only weakly.
    @ObservationIgnored private var subtitleLoader: SubtitleInjectingResourceLoader?
    /// Off-critical-path default-subtitle pick. Runs concurrently with playback
    /// startup so resolving the asset's `AVMediaSelectionGroup` never extends the
    /// time-to-first-frame; cancelled on teardown so a stale selection never
    /// applies to a replaced player item.
    @ObservationIgnored private var defaultSubtitleSelectionTask: Task<Void, Never>?
    /// Off-critical-path preferred-audio-language pick (per-series memory /
    /// prefer-original-language). AVPlayer otherwise just plays the asset's default
    /// audio track, so without this the audio half of those features no-ops on the
    /// native engine. Cancelled on teardown so a stale selection never applies to a
    /// replaced player item.
    @ObservationIgnored private var preferredAudioSelectionTask: Task<Void, Never>?
    #if !os(macOS)
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var endOfPlaybackObserver: NSObjectProtocol?
    #endif
    #if canImport(UIKit)
    /// A single, stable `AVPlayerLayer`-backed surface fed by whichever
    /// `AVPlayer` is live, so a transcode-fallback swap re-points the existing
    /// surface instead of forcing the SwiftUI layer to rebuild it.
    @ObservationIgnored private var videoOutputView: PlayerLayerView?
    #endif
    #if os(tvOS)
    /// The dynamic-range display switch tvOS should request for the current
    /// source (Dolby Vision / HDR10 / HLG). `nil` for SDR or before a load.
    /// Retained so it can be (re)applied once the output view is in a window.
    @ObservationIgnored private var pendingDisplayCriteria: AVDisplayCriteria?
    /// The window whose `AVDisplayManager` we last drove, so teardown can clear
    /// the preference even after the view has left its window — otherwise the TV
    /// can be stranded in a forced HDR/DoVi mode.
    @ObservationIgnored private weak var displayCriteriaWindow: UIWindow?
    #endif

    public init(
        style: SubtitleStyle = .default,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? = nil
    ) {
        self.style = style
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
        PlaybackInstrumentation.increment(.nativeEngine)
    }

    deinit {
        PlaybackInstrumentation.decrement(.nativeEngine)
    }

    public let displayName = "AVPlayer"

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
        let streamURL: URL?
        if case .some(.authenticatedHTTP(let locator)) = request.playbackSource {
            do {
                streamURL = try await authenticatedHTTPResolver?.resolve(locator)
            } catch {
                let appError = AppError.unknown(String(describing: error))
                status = .failed(appError)
                onFailure?(appError)
                return
            }
        } else {
            streamURL = request.streamURL ?? request.playbackSource?.publicURL
        }
        guard let streamURL else {
            let error = AppError.unknown("Native playback requires a URL source")
            status = .failed(error)
            onFailure?(error)
            return
        }

        let injectableSubtitles = await resolveInjectableSubtitles(for: request)
        let asset = makeAsset(
            for: request,
            streamURL: streamURL,
            injectableSubtitles: injectableSubtitles
        )
        let item = AVPlayerItem(asset: asset)
        // Apply in-app subtitle styling overrides if the user set any.
        item.textStyleRules = style.textStyleRules()
        // Drive the tvOS display into the right dynamic range (true Dolby
        // Vision / HDR10 / HLG) for this source before playback begins.
        configureDynamicRange(for: request, item: item)

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

        // Watch for an item that plays audio but renders no video (e.g. an HEVC
        // stream AVPlayer can't display) so we can swap to the on-device engine.
        monitorForMissingVideo(item: item, request: request)

        // Auto-notify when this item plays through to its natural end so the
        // owner can react (e.g. dismiss a finished trailer).
        observeEndOfPlayback(item: item)

        // Inspect the *real* container video format as soon as it loads (in
        // parallel — adds no startup delay) so a known AVPlayer-hostile codec can
        // swap to the on-device engine near-instantly, before the no-frames probe.
        inspectVideoFormat(asset: asset, request: request)

        installTimeObserver(on: player)
        status = .ready
        isPaused = false
        player.playImmediately(atRate: Float(currentPlaybackRate))

        // Plozz owns subtitle SELECTION and DRAWING through its SDR overlay (see
        // PlayerViewModel.applyInitialSubtitleSelectionIfReady). The native engine
        // must therefore NOT enable any AVPlayer legible option — otherwise
        // AVPlayer would paint the asset's default/forced/autoselect subtitle into
        // the (HDR) video signal in parallel with the overlay: a double-draw that
        // also defeats HDR-safe rendering. Disable the legible group on load so
        // the overlay stays the single source of truth. Detached from load()'s
        // critical path because resolving the asset's `AVMediaSelectionGroup`
        // involves extra I/O the first video frame must not wait on. Cancelled in
        // `teardownPlayer` so it never applies to a replaced player item.
        defaultSubtitleSelectionTask?.cancel()
        defaultSubtitleSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.disableLegibleSubtitleSelection(for: item)
        }

        // Apply the resolved audio-language preference (per-series memory /
        // prefer-original-language) the same off-critical-path way. AVPlayer has no
        // load-time language option, so we select the best-matching audible track
        // once its `AVMediaSelectionGroup` resolves. Empty preference => leave the
        // asset's default audio untouched (the no-feature common case). The viewer's
        // later manual pick (`selectAudioTrack`) still overrides this freely.
        preferredAudioSelectionTask?.cancel()
        let preferredAudioLanguages = request.preferredAudioLanguages
        if !preferredAudioLanguages.isEmpty {
            preferredAudioSelectionTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.applyPreferredAudioSelection(
                    for: item,
                    preferredLanguages: preferredAudioLanguages
                )
            }
        }
    }

    // MARK: - Dynamic range / Dolby Vision display switch

    /// Classifies the source's dynamic range and, on tvOS, requests the matching
    /// display mode so the Apple TV negotiates true Dolby Vision / HDR10 / HLG
    /// (or returns to SDR) with the panel. `appliesPerFrameHDRDisplayMetadata`
    /// is enabled for HDR/DoVi so per-frame RPU/HDR metadata is forwarded to the
    /// display. All best-effort and crash-safe: failures never block playback.
    private func configureDynamicRange(for request: PlaybackRequest, item: AVPlayerItem) {
        let mode = HDRDisplayMode(request.sourceMetadata)
        item.appliesPerFrameHDRDisplayMetadata = mode.isHDR
        #if os(tvOS)
        pendingDisplayCriteria = makeDisplayCriteria(mode: mode, metadata: request.sourceMetadata)
        applyDisplayCriteria()
        #endif
    }

    #if os(tvOS)
    /// Pushes `pendingDisplayCriteria` onto the output view's window manager. Safe
    /// to call before the view is in a window — it re-runs from the view's
    /// `onWindowChange` hook once a window is available.
    private func applyDisplayCriteria() {
        guard let window = videoOutputView?.window, Self.windowHasDisplayManager(window) else { return }
        displayCriteriaWindow = window
        window.avDisplayManager.preferredDisplayCriteria = pendingDisplayCriteria
    }

    /// Clears any forced display mode so the TV isn't stranded in HDR/DoVi after
    /// playback stops.
    private func clearDisplayCriteria() {
        pendingDisplayCriteria = nil
        if let window = displayCriteriaWindow, Self.windowHasDisplayManager(window) {
            window.avDisplayManager.preferredDisplayCriteria = nil
        }
        displayCriteriaWindow = nil
    }

    /// Safety net: the `avDisplayManager` accessor comes from AVKit's
    /// `UIWindow (AVAdditions)` category. If that framework somehow isn't linked,
    /// the selector is unrecognized and calling it would crash — so verify it's
    /// present first and degrade to a no-op (no display switch) instead.
    private static func windowHasDisplayManager(_ window: UIWindow) -> Bool {
        window.responds(to: Selector(("avDisplayManager")))
    }
    #endif

    // MARK: - Asset construction

    /// Builds the asset to play. When the server is direct-playing the original
    /// file (not transcoding) and the item has text subtitles the player would
    /// otherwise never see, wrap the stream in a synthesized HLS playlist that
    /// adds those subtitles as selectable renditions. Otherwise play the stream
    /// URL directly (transcoded HLS already carries subtitles in its manifest).
    private func makeAsset(
        for request: PlaybackRequest,
        streamURL: URL,
        injectableSubtitles: [InjectableSubtitle]
    ) -> AVURLAsset {
        subtitleLoader = nil
        guard !request.isManifestStream else {
            return AVURLAsset(url: streamURL)
        }
        guard !injectableSubtitles.isEmpty,
              let duration = request.item.runtime,
              duration > 0 else {
            return AVURLAsset(url: streamURL)
        }
        let composer = SubtitleHLSComposer(
            videoURL: streamURL,
            durationSeconds: duration,
            subtitles: injectableSubtitles
        )
        let loader = SubtitleInjectingResourceLoader(composer: composer)
        subtitleLoader = loader
        return loader.makeAsset()
    }

    private func resolveInjectableSubtitles(
        for request: PlaybackRequest
    ) async -> [InjectableSubtitle] {
        guard !request.isManifestStream else { return [] }
        var result: [InjectableSubtitle] = []
        for track in request.subtitleTracks where track.kind == .subtitle {
            guard let source = track.deliverySource else { continue }
            let url: URL?
            switch source {
            case .localFile(let localURL):
                url = localURL
            case .authenticatedHTTP(let locator):
                url = try? await authenticatedHTTPResolver?.resolve(locator)
            }
            guard let url else { continue }
            result.append(
                InjectableSubtitle(
                    index: track.id,
                    name: track.displayTitle,
                    languageTag: track.language,
                    isDefault: track.isDefault,
                    isForced: track.isForced,
                    sourceURL: url
                )
            )
        }
        return result
    }

    public func play() {
        guard let player else { return }
        player.playImmediately(atRate: Float(currentPlaybackRate))
        isPaused = false
    }

    public func pause() {
        guard let player else { return }
        player.pause()
        isPaused = true
    }

    // MARK: - Tunables

    /// AVPlayer can change `rate` live with no reload, so we advertise speed.
    /// Audio/subtitle delay are not exposed by AVPlayer in a useful way (it
    /// owns the audio mix in the asset graph), so we honestly opt out instead
    /// of pretending — the menu hides those rows for this engine.
    public var capabilities: PlayerEngineCapabilities { [.playbackSpeed] }

    /// Last requested speed, so a subsequent play() doesn't snap back to 1.0
    /// (AVPlayer resets rate to 1.0 on pause and on some item transitions).
    @ObservationIgnored private var currentPlaybackRate: Double = 1.0

    public func setPlaybackSpeed(_ rate: Double) {
        let clamped = max(0.25, min(4.0, rate))
        currentPlaybackRate = clamped
        // Only push to AVPlayer when playing — pausing then re-setting `rate`
        // would silently un-pause the player.
        if let player, !isPaused {
            player.rate = Float(clamped)
        }
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
        #if os(tvOS)
        clearDisplayCriteria()
        #endif
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

    /// Reads the actual **video and audio** codec FourCCs from the asset's track
    /// format descriptions and, if either is one AVPlayer can't handle (e.g. HEVC
    /// `hev1` → black screen, Opus → silent), swaps to the on-device engine
    /// immediately. Runs concurrently with playback start so it adds **no startup
    /// delay**: the happy path keeps playing while this resolves (typically
    /// sub-second, before the first frame paints), and a hostile codec swaps
    /// near-instantly rather than after the slower no-frames probe.
    ///
    /// This asks the container itself rather than trusting server metadata (which
    /// for some files reports no codec tag at all). Scoped to **SDR** so the
    /// validated AVPlayer Dolby Vision/HDR path is left untouched.
    private func inspectVideoFormat(asset: AVAsset, request: PlaybackRequest) {
        formatInspectTask?.cancel()
        guard HDRDisplayMode(request.sourceMetadata) == .sdr else { return }
        let expectsVideo = request.sourceMetadata?.video != nil

        formatInspectTask = Task { [weak self] in
            // Video: an AVPlayer-hostile codec (e.g. HEVC `hev1`) plays audio over
            // a black screen.
            if expectsVideo, let videoFourCC = await Self.firstCodecFourCC(of: asset, mediaType: .video) {
                guard let self, !Task.isCancelled else { return }
                PlozzLog.playback.info("Direct-play video codec FourCC: \(videoFourCC)")
                if Self.isAVPlayerHostileVideoFourCC(videoFourCC) {
                    PlozzLog.playback.info("Video FourCC \(videoFourCC) is not reliably rendered by AVPlayer; swapping to the on-device engine")
                    self.onFailure?(.invalidResponse)
                    return
                }
            }

            // Audio: a codec AVPlayer can't decode (Opus/Vorbis) plays video with
            // no sound — the no-frames probe can't catch this, so check it here.
            if let audioFourCC = await Self.firstCodecFourCC(of: asset, mediaType: .audio) {
                guard let self, !Task.isCancelled else { return }
                PlozzLog.playback.info("Direct-play audio codec FourCC: \(audioFourCC)")
                if Self.isAVPlayerHostileAudioFourCC(audioFourCC) {
                    PlozzLog.playback.info("Audio FourCC \(audioFourCC) is not decodable by AVPlayer; swapping to the on-device engine")
                    self.onFailure?(.invalidResponse)
                }
            }
        }
    }

    /// Loads the first track of `mediaType`'s codec FourCC from the container.
    private static func firstCodecFourCC(of asset: AVAsset, mediaType: AVMediaType) async -> String? {
        do {
            let tracks = try await asset.loadTracks(withMediaType: mediaType)
            guard let track = tracks.first else { return nil }
            let formats = try await track.load(.formatDescriptions)
            guard let format = formats.first else { return nil }
            return fourCCString(CMFormatDescriptionGetMediaSubType(format))
        } catch {
            return nil
        }
    }

    /// HEVC tagged `hev1` (in-band parameter sets) in an MP4-family container
    /// plays audio with a black screen on AVPlayer/VideoToolbox. `hvc1`/`avc1`
    /// are fine. (DoVi is excluded upstream via the SDR gate.)
    private static func isAVPlayerHostileVideoFourCC(_ fourCC: String) -> Bool {
        fourCC.lowercased() == "hev1"
    }

    /// Audio FourCCs AVPlayer can't decode (Opus `Opus`, Vorbis). AAC `mp4a`,
    /// AC-3 `ac-3`, E-AC-3 `ec-3`, ALAC, FLAC, LPCM etc. are all fine.
    private static func isAVPlayerHostileAudioFourCC(_ fourCC: String) -> Bool {
        let lowered = fourCC.lowercased()
        return lowered == "opus" || lowered.contains("vorbis")
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let scalars = bytes.map { Character(UnicodeScalar($0)) }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }


    /// and decodes audio, but **no video frame ever decodes** (e.g. an HEVC stream
    /// tagged `hev1`, or a profile VideoToolbox rejects). Because AVPlayer never
    /// errors, the normal failure path never fires — so we attach a lightweight
    /// `AVPlayerItemVideoOutput` and, if several seconds of playback advance with
    /// zero decoded frames, hand off to the on-device hybrid engine (which decodes
    /// these directly) via the standard engine-swap fallback.
    ///
    /// Scoped to **SDR** sources: HDR/Dolby Vision is the validated AVPlayer-only
    /// path (and DoVi/HDR HEVC is always `hvc1`, so it never hits this), so it's
    /// left completely untouched. The probe removes itself the moment a real frame
    /// appears, so healthy playback pays almost nothing.
    private func monitorForMissingVideo(item: AVPlayerItem, request: PlaybackRequest) {
        missingVideoProbeTask?.cancel()
        // Only meaningful when the source is expected to have video.
        guard request.sourceMetadata?.video != nil else { return }
        // Never probe HDR/Dolby Vision — protect the validated AVPlayer HDR path.
        guard HDRDisplayMode(request.sourceMetadata) == .sdr else { return }

        let output = AVPlayerItemVideoOutput(outputSettings: nil)
        item.add(output)

        missingVideoProbeTask = Task { [weak self] in
            // Require this many seconds of *advancing* playback with no video frame
            // before declaring the video undecodable (generous, to avoid tripping
            // on slow starts / buffering).
            let requiredAdvance: Double = 4
            var advanced: Double = 0
            var lastSeconds = Double.nan

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, let player = self.player,
                      player.currentItem === item else { return }

                // A decoded frame appeared → video is fine; drop the probe.
                if output.hasNewPixelBuffer(forItemTime: player.currentTime()) {
                    item.remove(output)
                    return
                }

                // Only accrue progress while genuinely playing (ignore pause/seek/
                // buffering), so the threshold reflects real played-through time.
                guard player.timeControlStatus == .playing else { continue }
                let now = player.currentTime().seconds
                if now.isFinite, lastSeconds.isFinite, now > lastSeconds {
                    advanced += now - lastSeconds
                }
                if now.isFinite { lastSeconds = now }

                if advanced >= requiredAdvance {
                    item.remove(output)
                    PlozzLog.playback.info("AVPlayer rendered no video after \(Int(requiredAdvance))s of audio; swapping to the on-device engine")
                    self.onFailure?(.invalidResponse)
                    return
                }
            }
        }
    }

    /// Tears the current player down without touching the audio-session or
    /// route-change observers. Used both when reloading for a retry and as part
    /// of `stop()`.
    /// Observes the natural end of `item` so the owner can react (e.g. dismiss a
    /// finished trailer). `didPlayToEndTimeNotification` fires only on a clean
    /// playthrough — never on a user-initiated stop or a failure — so it's a safe
    /// auto-dismiss trigger. Scoped to this specific item; removed in
    /// `teardownPlayer`.
    private func observeEndOfPlayback(item: AVPlayerItem) {
        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
        }
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onEnded?()
            }
        }
    }

    private func teardownPlayer() {
        fallbackMonitorTask?.cancel()
        fallbackMonitorTask = nil
        missingVideoProbeTask?.cancel()
        missingVideoProbeTask = nil
        formatInspectTask?.cancel()
        formatInspectTask = nil
        defaultSubtitleSelectionTask?.cancel()
        defaultSubtitleSelectionTask = nil
        preferredAudioSelectionTask?.cancel()
        preferredAudioSelectionTask = nil
        subtitleLoader = nil
        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
        }
        endOfPlaybackObserver = nil
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
        await seek(player: player, to: seconds, kind: .exact)
    }

    public func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        guard let player else { return }
        await seek(player: player, to: seconds, kind: kind)
    }

    /// Waits (briefly) for the player item to become ready before seeking. A
    /// resume seek issued before the asset is ready — common for far positions —
    /// is silently dropped by AVPlayer, leaving playback at 0.
    private func seekWhenReady(player: AVPlayer, to seconds: TimeInterval) async {
        guard let item = player.currentItem else { return }
        PlaybackTrace.note("NATIVE resumeSeek WAIT to=\(String(format: "%.2f", seconds)) status=\(item.status.rawValue)")
        let deadline = Date().addingTimeInterval(5)
        // 20ms poll keeps resume start-up snappy: most assets reach
        // `.readyToPlay` within one or two ticks, instead of waiting out a
        // coarse 50ms slot before the seek can fire.
        while item.status != .readyToPlay, Date() < deadline {
            if item.status == .failed { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        PlaybackTrace.note("NATIVE resumeSeek FIRE to=\(String(format: "%.2f", seconds)) status=\(item.status.rawValue)")
        await seek(player: player, to: seconds)
    }

    private func seek(player: AVPlayer, to seconds: TimeInterval) async {
        await seek(player: player, to: seconds, kind: .exact)
    }

    private func seek(player: AVPlayer, to seconds: TimeInterval, kind: VideoSeekKind) async {
        let target = seekTarget(seconds, item: player.currentItem)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        // `.fast` widens the tolerance so AVPlayer can snap to the nearest
        // available keyframe and return immediately — the right behaviour for
        // intermediate seeks in a rapid-skip burst that will be superseded by a
        // later, exact seek. `.exact` keeps a tight 1s tolerance: exact (.zero)
        // seeks can stall or fail on transcoded HLS, so 1s is the sweet spot.
        let toleranceSeconds: Double = kind == .fast ? 5 : 1
        let tolerance = CMTime(seconds: toleranceSeconds, preferredTimescale: 600)
        if PlaybackTrace.enabled {
            let (lo, hi) = seekableBounds(item: player.currentItem)
            let clamped = abs(target - max(0, seconds)) > 0.5
            PlaybackTrace.note("NATIVE seek BEGIN req=\(String(format: "%.2f", seconds)) target=\(String(format: "%.2f", target))\(clamped ? " CLAMPED" : "") kind=\(kind) seekable=[\(String(format: "%.2f", lo)),\(String(format: "%.2f", hi))] status=\(player.currentItem?.status.rawValue ?? -9) tcs=\(player.timeControlStatus.rawValue)")
        }
        await player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        PlaybackTrace.note("NATIVE seek END   target=\(String(format: "%.2f", target)) curr=\(String(format: "%.2f", player.currentTime().seconds)) tcs=\(player.timeControlStatus.rawValue)")
    }

    private func seekTarget(_ seconds: TimeInterval, item: AVPlayerItem?) -> TimeInterval {
        return clampToSeekableRange(seconds, item: item)
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

    /// Diagnostic: the merged [lower, upper] of the item's seekable ranges, or
    /// [0, 0] when none are known yet. Used only by `PLZSEEK` tracing.
    private func seekableBounds(item: AVPlayerItem?) -> (Double, Double) {
        guard let ranges = item?.seekableTimeRanges, !ranges.isEmpty else { return (0, 0) }
        var lower = TimeInterval.greatestFiniteMagnitude
        var upper = 0.0
        for value in ranges {
            let range = value.timeRangeValue
            lower = min(lower, range.start.seconds)
            upper = max(upper, (range.start + range.duration).seconds)
        }
        return (lower == .greatestFiniteMagnitude ? 0 : lower, upper)
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

    /// Disables AVPlayer's legible (subtitle) selection on the player item so the
    /// engine never draws a subtitle itself. Plozz routes the user's default and
    /// manual subtitle choices through its own SDR overlay
    /// (`PlayerViewModel.applyInitialSubtitleSelectionIfReady` /
    /// `selectSubtitleOption`), which fetches/decodes the same track and renders
    /// it HDR-safely on top of the video. Selecting `nil` here also overrides any
    /// `default`/`autoselect`/forced characteristic the asset (or an injected HLS
    /// rendition) would otherwise honour. Best-effort: failure simply leaves
    /// AVPlayer's own selection untouched and never affects playback.
    private func disableLegibleSubtitleSelection(for item: AVPlayerItem) async {
        guard let group = await legibleGroup(for: item.asset) else { return }
        item.select(nil, in: group)
    }

    /// Selects the audible track best matching an ordered list of preferred
    /// languages (per-series memory / prefer-original-language). Uses
    /// `mediaSelectionOptions(from:filteredAndSortedAccordingToPreferredLanguages:)`
    /// so language identifiers are canonicalised — a preference of `"jpn"` matches
    /// an option tagged `"ja"`, and vice versa — and the result is ordered by the
    /// preference list. Best-effort: no match (or no audible group) leaves the
    /// asset's default audio untouched and never affects playback.
    private func applyPreferredAudioSelection(
        for item: AVPlayerItem,
        preferredLanguages: [String]
    ) async {
        guard !preferredLanguages.isEmpty,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        else { return }
        let ranked = AVMediaSelectionGroup.mediaSelectionOptions(
            from: group.options,
            filteredAndSortedAccordingToPreferredLanguages: preferredLanguages
        )
        guard let best = ranked.first else { return }
        item.select(best, in: group)
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

    /// Re-applies subtitle styling to the *current* player item so an in-player
    /// Style edit updates an embedded text track AVFoundation draws itself (e.g. an
    /// MKV SRT on Plex direct-play, which has no sidecar the overlay could redraw).
    /// Harmless for overlay-drawn subtitles: AVFoundation's legible selection is off
    /// in that case, so it isn't rendering a track for these rules to affect.
    public func updateSubtitleStyle(_ style: SubtitleStyle) {
        self.style = style
        player?.currentItem?.textStyleRules = style.textStyleRules()
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
        #if os(tvOS)
        // Re-apply the pending display switch once the surface has a window
        // (the criteria may have been computed in load() before attachment).
        view.onWindowChange = { [weak self] _ in
            self?.applyDisplayCriteria()
        }
        #endif
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
    #if os(tvOS)
    /// Invoked when the view moves to (or away from) a window, so the engine can
    /// drive that window's `AVDisplayManager` for the Dolby Vision / HDR switch.
    var onWindowChange: ((UIWindow?) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
    #endif
}
#endif
#endif
