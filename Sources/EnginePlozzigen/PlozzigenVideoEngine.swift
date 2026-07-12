#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Combine
import CoreModels
import FeaturePlayback
#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import AetherEngine
@preconcurrency import AetherEngineSMB

// The module and main class are both named "AetherEngine", so we typealias
// the class to avoid ambiguity. All other public types (LoadOptions,
// AetherPlayerView, etc.) are resolved from the module import directly.
private typealias AEEngine = AetherEngine

/// `VideoEngine` implementation backed by AetherEngine (branded "Plozzigen").
///
/// AetherEngine handles the full native pipeline internally:
/// FFmpeg demux → on-device copy-remux → localhost HLS-fMP4 → AVPlayer.
/// This gives us: Dolby Vision, Atmos passthrough, full-timeline seek,
/// bounded memory (segment cache + backpressure), and producer-restart seek.
///
/// This adapter maps AetherEngine's published state to Plozz's `VideoEngine`
/// protocol so it plugs into the existing `PlayerViewModel` / routing
/// infrastructure without changes to the rest of the app.
@MainActor
public final class PlozzigenVideoEngine: VideoEngine {

    // MARK: - VideoEngine State

    public private(set) var status: VideoEngineStatus = .idle
    public private(set) var isPaused: Bool = true
    /// Our *intended* transport state — the single source of truth for whether
    /// the user wants to be playing. AetherEngine's "producer-restart" seek tears
    /// down and rebuilds the pipeline, which re-emits a `.playing` state the
    /// instant it restarts — even when we committed a seek *while paused* (a
    /// pause-to-seek scrub). Mirroring that phantom `.playing` would flip us to
    /// "playing" with a frozen picture. We gate the observer on this so a held
    /// pause stays held until the user explicitly resumes.
    private var intendsPause: Bool = true
    public private(set) var furthestObservedPosition: TimeInterval = 0
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []

    public var currentTime: TimeInterval { engine.currentTime }
    public var duration: TimeInterval { engine.duration }

    /// Ground truth for the menu's "selected audio" indicator: the AVStream index
    /// AetherEngine is actually decoding (its resolved `activeAudioTrackIndex`),
    /// which can differ from the container `isDefault` flag because the engine
    /// honors the viewer's audio-language preference at load. `TrackInfo.id`,
    /// `selectAudioTrack(index:)`, and `activeAudioTrackIndex` all share the
    /// FFmpeg AVStream-index space, so this maps directly onto `MediaTrack.id`.
    public var currentAudioTrackID: Int? { engine.activeAudioTrackIndex }
    public var bufferedPosition: TimeInterval { engine.clock.bufferedPosition }

    /// Bridge AetherEngine's live telemetry into the diagnostics overlay so the
    /// Plozzigen path shows real dropped frames / observed FPS / bitrate instead
    /// of `-` (it has no `AVPlayer`, so the access-log path never fires).
    public var liveTelemetry: EngineLiveTelemetry? {
        guard let t = engine.liveTelemetry else { return nil }
        return EngineLiveTelemetry(
            droppedFrameCount: t.droppedFrameCount,
            observedFps: t.observedFps,
            observedBitrate: t.instantBitrateMbps.map { $0 * 1_000_000 }
        )
    }

    /// Surface AetherEngine's own probe (real dynamic range, audio, dimensions)
    /// so SMB shares — which carry no provider metadata — still show accurate
    /// diagnostics. Gated on the probe actually having run (`sourceVideoWidth > 0`)
    /// so we publish nothing until it's known, rather than the `.sdr` default of
    /// AetherEngine's `sourceVideoFormat` before a source is opened.
    public var probedSourceFacts: EngineProbedSourceFacts? {
        guard engine.sourceVideoWidth > 0 else { return nil }
        let range: EngineProbedSourceFacts.DynamicRange = switch engine.sourceVideoFormat {
        case .sdr: .sdr
        case .hdr10: .hdr10
        case .hdr10Plus: .hdr10Plus
        case .hlg: .hlg
        case .dolbyVision: .dolbyVision
        }
        let active = engine.activeAudioTrackIndex.flatMap { idx in
            engine.audioTracks.first { $0.id == idx }
        } ?? engine.audioTracks.first { $0.isDefault } ?? engine.audioTracks.first
        let w = Int(engine.sourceVideoWidth)
        let h = Int(engine.sourceVideoHeight)
        return EngineProbedSourceFacts(
            range: range,
            videoWidth: w > 0 ? w : nil,
            videoHeight: h > 0 ? h : nil,
            videoDecoder: engine.activeVideoDecoder,
            audioCodec: active?.codec,
            audioChannels: active.map(\.channels).flatMap { $0 > 0 ? $0 : nil },
            audioIsAtmos: active?.isAtmos ?? false,
            audioDecoder: engine.activeAudioDecoder
        )
    }

    public var preventsDisplaySleep: Bool {
        engine.state == .playing
    }

    public var displayName: String { "Plozzigen" }

    public var capabilities: PlayerEngineCapabilities {
        [.playbackSpeed, .dualSubtitleDecode]
    }

    deinit {
        progressTimer?.cancel()
    }

    // MARK: - Callbacks

    public var onProgress: (@MainActor () -> Void)?
    public var onFailure: (@MainActor (AppError) -> Void)?
    public var onEnded: (@MainActor () -> Void)?
    /// Fired after `syncTracks()` re-reads AetherEngine's async-published track
    /// lists, so the VM can repopulate its (otherwise-empty-at-load) options menu.
    public var onTracksChanged: (@MainActor () -> Void)?
    /// Fired with AetherEngine's decoded subtitle cues (text + bitmap), mapped to
    /// Plozz's cue model, so the owned overlay draws them. This is the decoded
    /// read-ahead buffer — the host time-filters it against the playhead.
    public var onSubtitleCues: (@MainActor ([CoreModels.SubtitleCue]) -> Void)?
    /// Fired with AetherEngine's decoded *secondary* (dual-line) subtitle cues,
    /// mapped to Plozz's cue model, so the owned overlay draws a second line from
    /// the container itself — no fetchable sidecar URL needed. This is what makes
    /// dual subtitles work for embedded tracks (e.g. Plex direct-play MKV).
    public var onSecondarySubtitleCues: (@MainActor ([CoreModels.SubtitleCue]) -> Void)?

    // MARK: - Private

    private let engine: AEEngine
    private var cancellables = Set<AnyCancellable>()
    private var progressTimer: Task<Void, Never>?
    /// Tags every load/restore so deferred Combine state from a superseded
    /// operation cannot fail or revive the replacement operation.
    private var lifecycleGeneration = 0
    private var reportedFailureGeneration: Int?
    #if canImport(UIKit)
    private let videoView: UIView
    #endif

    // MARK: - Init

    public init() throws {
        self.engine = try AEEngine()
        #if canImport(UIKit)
        let surface = AetherPlayerView()
        engine.bind(view: surface)
        self.videoView = surface
        #endif
        installEngineLogMirror()
        observeEngine()
    }

    /// Mirror AetherEngine's own diagnostics (`EngineLog`) to our `PLZSEEK` stdout
    /// channel when seek tracing is on. This surfaces the engine's internal
    /// decisions verbatim — most importantly the `seek(to:) ignored: no active
    /// session (state=.ended)` line that proves a backward seek after end-of-media
    /// is a no-op. Gated, so it's free (and unhooked) in normal runs.
    private func installEngineLogMirror() {
        let trace = PlaybackTrace.enabled
        let handoff = HandoffDiagnostics.isEnabled
        guard trace || handoff else { return }
        EngineLog.handler = { line in
            if trace { PlaybackTrace.note("AE " + line) }
            // Forward AetherEngine's load() phase timings AND display-criteria
            // apply/reset lines to the hand-off telemetry stdout channel, so
            // time-to-first-frame and the panel HDR/DV enter/exit are visible on
            // device (e.g. confirm the panel resets to SDR when a title ends).
            if handoff, line.contains("[TTFF]") || line.contains("[DisplayCriteria]") {
                HandoffDiagnostics.emit("aether " + line)
            }
        }
    }

    // MARK: - VideoEngine Lifecycle

    public func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        let generation = beginLifecycleOperation()
        status = .loading
        isPaused = false
        intendsPause = false
        furthestObservedPosition = startPosition

        // Prefer the original range-readable URL (MKV bytes with embedded auth)
        // for sources that have a localRemuxSource descriptor; AetherEngine
        // handles the remux pipeline internally. Fall back to streamURL for
        // standard HLS / direct-play URLs.
        let url = request.localRemuxSource?.originalURL ?? request.streamURL

        // For >6-channel sources (7.1), prefer the lossless FLAC bridge so the
        // full 7.1 layout survives — the default `.surroundCompat` EAC3 bridge caps
        // at 5.1. Multichannel-LPCM AVRs get true 7.1; stereo-only routes downmix
        // gracefully. Either way it's an on-device bridge, never a server transcode.
        let channels = request.localRemuxSource?.sourceMetadata.audio?.channels
            ?? request.sourceMetadata?.audio?.channels ?? 0
        var options = LoadOptions(
            matchContentEnabled: true,
            audioBridgeMode: channels > 6 ? .lossless : .surroundCompat
        )
        // Steer the INITIAL active audio/subtitle track via language preference
        // (no reload). Computed upstream from per-series memory / prefer-original
        // policy. Empty arrays express no preference (container default wins).
        options.preferredAudioLanguages = request.preferredAudioLanguages
        options.preferredSubtitleLanguages = request.preferredSubtitleLanguages

        do {
            if url.scheme?.lowercased() == "smb" {
                // Media-share transport (second-class, behind Plex/Jellyfin). The
                // provider mints a per-play `smb://user:password@host/share/path`
                // URL with in-memory credentials; nothing is persisted here. We
                // wrap it in an `IOReader` custom source so AetherEngine demuxes
                // the raw file over SMB with no server-side transcode.
                let source = try await makeSMBSource(from: url)
                try await engine.load(
                    source: source,
                    startPosition: startPosition > 0 ? startPosition : nil,
                    options: options
                )
            } else {
                try await engine.load(
                    url: url,
                    startPosition: startPosition > 0 ? startPosition : nil,
                    options: options
                )
            }
            guard generation == lifecycleGeneration, status != .idle else { return }
            if case .failed = status { return }
            engine.play()
            status = .ready
            syncTracks()
        } catch {
            // Surface the real reason: AppError / SMBConnection.SMBError don't
            // conform to LocalizedError, so `localizedDescription` collapses to a
            // generic "error 0". `String(describing:)` keeps the actual message.
            let detail = String(describing: error)
            let err: AppError = .unknown(detail)
            reportFailureIfNeeded(err, generation: generation)
        }
    }

    // MARK: - SMB custom source

    /// Build an SMB `MediaSource` from an `smb://host[:port]/share/path/file.ext`
    /// URL. Parses it with the engine's `SMBURL`, opens an `SMBConnection`
    /// (NWConnection-backed SMB2, NTLMv2 / guest, read-only), and wraps it in an
    /// `SMBIOReader` for the engine's custom-source path.
    private func makeSMBSource(from url: URL) async throws -> MediaSource {
        let parsed: SMBURL
        do {
            parsed = try SMBURL.parse(url.absoluteString)
        } catch {
            throw AppError.unknown("Malformed SMB URL: \(String(describing: error))")
        }
        let connection = try await SMBConnection.connect(
            server: parsed.server,
            share: parsed.share,
            path: parsed.path,
            user: parsed.user,
            password: parsed.password
        )
        return .custom(SMBIOReader(source: connection), formatHint: Self.smbFormatHint(for: parsed.path))
    }

    /// Optional container short-name hint for the demuxer probe, derived from the
    /// file extension (there is no server MIME type for a raw share file). nil
    /// lets AetherEngine probe from content.
    private static func smbFormatHint(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "mkv":                 return "matroska"
        case "webm":                return "webm"
        case "mp4", "m4v", "mov":   return "mp4"
        case "ts", "m2ts", "mts":   return "mpegts"
        case "avi":                 return "avi"
        default:                    return nil
        }
    }

    public func play() {
        intendsPause = false
        engine.play()
        isPaused = false
    }

    public func pause() {
        intendsPause = true
        engine.pause()
        isPaused = true
    }

    public func restoreAfterBackground() async {
        guard status != .idle else { return }
        let generation = beginLifecycleOperation()
        status = .loading
        do {
            try await engine.reloadAtCurrentPosition()
            guard generation == lifecycleGeneration, status != .idle else { return }
            if case .failed = status { return }
            if intendsPause {
                engine.pause()
                isPaused = true
            } else {
                engine.play()
                isPaused = false
            }
            status = .ready
            syncTracks()
        } catch {
            let err: AppError = .unknown(String(describing: error))
            reportFailureIfNeeded(err, generation: generation)
        }
    }

    public func seek(to seconds: TimeInterval) async {
        await engine.seek(to: seconds)
    }

    public func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        PlaybackTrace.note("engine.seek BEGIN target=\(String(format: "%.2f", seconds)) kind=\(kind) state=\(engine.state) curr=\(String(format: "%.2f", currentTime)) dur=\(String(format: "%.2f", duration))")
        await engine.seek(to: seconds)
        PlaybackTrace.note("engine.seek END   target=\(String(format: "%.2f", seconds)) state=\(engine.state) curr=\(String(format: "%.2f", currentTime))")
    }

    public func stop() {
        stopEngine(resetDisplayCriteria: true)
    }

    /// Same-dynamic-range hand-off: when asked to preserve the display mode, stop
    /// AetherEngine WITHOUT nil-ing `preferredDisplayCriteria`, so the panel stays
    /// in its current HDR/DV mode. The incoming episode's engine re-applies the
    /// identical criteria, so tvOS performs no re-sync (no DV→SDR→DV flap).
    public func stop(preserveDisplayMode: Bool) {
        stopEngine(resetDisplayCriteria: !preserveDisplayMode)
    }

    private func stopEngine(resetDisplayCriteria: Bool) {
        lifecycleGeneration &+= 1
        reportedFailureGeneration = nil
        progressTimer?.cancel()
        progressTimer = nil
        engine.stop(resetDisplayCriteria: resetDisplayCriteria)
        status = .idle
        intendsPause = true
        isPaused = true
    }

    // MARK: - Tunables

    public func setPlaybackSpeed(_ rate: Double) {
        engine.setRate(Float(rate))
    }

    public func setAudioDelay(_ seconds: TimeInterval) {}
    public func setSubtitleDelay(_ seconds: TimeInterval) {}
    public func setDialogEnhanceEnabled(_ enabled: Bool) {}

    // MARK: - Tracks

    public func selectAudioTrack(_ track: MediaTrack?) {
        guard let track else { return }
        engine.selectAudioTrack(index: track.id)
    }

    public func selectSubtitleTrack(_ track: MediaTrack?) {
        if let track {
            engine.selectSubtitleTrack(index: track.id)
        } else {
            engine.clearSubtitle()
        }
    }

    public func selectSecondarySubtitleTrack(_ track: MediaTrack?) {
        if let track {
            engine.selectSecondarySubtitleTrack(index: track.id)
        } else {
            engine.clearSecondarySubtitle()
        }
    }

    // MARK: - View

    #if canImport(UIKit)
    public func makeVideoOutputView() -> UIView {
        videoView
    }
    #endif

    // MARK: - Engine Observation (Combine)

    private func beginLifecycleOperation() -> Int {
        lifecycleGeneration &+= 1
        reportedFailureGeneration = nil
        return lifecycleGeneration
    }

    private func reportFailureIfNeeded(_ error: AppError, generation: Int) {
        guard generation == lifecycleGeneration,
              reportedFailureGeneration != generation,
              status != .idle else { return }
        reportedFailureGeneration = generation
        status = .failed(error)
        onFailure?(error)
    }

    private func observeEngine() {
        // State → status/isPaused/onEnded/onFailure
        engine.$state
            // Capture the lifecycle generation synchronously with the published
            // state. Delivery remains on the main queue, but an old `.error`
            // can no longer arrive after a replacement load and poison it.
            .map { [weak self] state in
                (self?.lifecycleGeneration ?? -1, state)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] generation, state in
                guard let self else { return }
                guard generation == self.lifecycleGeneration else { return }
                PlaybackTrace.note("engine.state -> \(state) intendsPause=\(self.intendsPause) curr=\(String(format: "%.2f", self.currentTime)) dur=\(String(format: "%.2f", self.duration))")
                switch state {
                case .idle:
                    break
                case .loading:
                    self.status = .loading
                case .playing:
                    // AetherEngine restarts its pipeline on a seek and re-emits
                    // `.playing` even when we committed the seek while paused. If
                    // the user intends to stay paused, treat that as a phantom:
                    // re-assert the pause on the engine and keep our paused state
                    // rather than surfacing a "playing" overlay over a held frame.
                    if self.intendsPause {
                        self.engine.pause()
                        self.isPaused = true
                        if self.status != .ready { self.status = .ready }
                    } else {
                        self.isPaused = false
                        self.status = .ready
                        self.startProgressTimer()
                    }
                case .paused:
                    self.isPaused = true
                    if self.status != .ready { self.status = .ready }
                case .seeking:
                    break
                case .ended:
                    self.onEnded?()
                case .error(let msg):
                    let err: AppError = .unknown(msg)
                    self.reportFailureIfNeeded(err, generation: generation)
                }
            }
            .store(in: &cancellables)

        // Track furthest observed position from clock ticks
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                if time > self.furthestObservedPosition {
                    self.furthestObservedPosition = time
                }
            }
            .store(in: &cancellables)

        // Sync track lists when AetherEngine publishes them
        engine.$audioTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTracks() }
            .store(in: &cancellables)
        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTracks() }
            .store(in: &cancellables)

        // AetherEngine resolves its active audio track asynchronously at load
        // (honoring the viewer's audio-language preference, which may override the
        // container default) and again on every track switch. Re-emit so the host
        // rebuilds its menu and highlights the track that's *actually* decoding —
        // otherwise the indicator stays on the default-flag guess and lies about
        // what's playing.
        engine.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onTracksChanged?() }
            .store(in: &cancellables)

        // Bridge AetherEngine's decoded cues into Plozz's owned overlay.
        // AetherEngine publishes its decoded *read-ahead* cue buffer (text +
        // bitmap) — not just the on-screen line — so `LiveSubtitleModel` filters it
        // by the playhead before drawing. Without this bridge, a selected
        // Plozzigen subtitle decodes but nothing is ever rendered — the "no
        // subtitles on Plozzigen" bug.
        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                // Map AetherEngine cues → Plozz's cue model inline so the
                // element type is inferred (the module and the engine class share
                // the name `AetherEngine`, so naming `AetherEngine.SubtitleCue`
                // explicitly is ambiguous here).
                let mapped: [CoreModels.SubtitleCue] = cues.map { cue in
                    let body: CoreModels.SubtitleCue.Body
                    switch cue.body {
                    case .text(let string):
                        body = .text(CoreModels.SubtitleText(string))
                    case .image(let image):
                        body = .image(CoreModels.SubtitleImage(
                            cgImage: image.cgImage,
                            normalizedRect: image.position
                        ))
                    }
                    return CoreModels.SubtitleCue(
                        id: cue.id,
                        start: cue.startTime,
                        end: cue.endTime,
                        body: body
                    )
                }
                self.onSubtitleCues?(mapped)
            }
            .store(in: &cancellables)

        // Same bridge for the SECONDARY (dual) channel: AetherEngine decodes a
        // second subtitle stream concurrently and publishes it here, so Plozz's
        // overlay can draw a dual line straight from the container — the path that
        // enables dual subtitles for embedded tracks (Plex direct-play) that have
        // no fetchable sidecar URL. Mapped inline for the same type-inference
        // reason as the primary above.
        engine.$secondarySubtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                let mapped: [CoreModels.SubtitleCue] = cues.map { cue in
                    let body: CoreModels.SubtitleCue.Body
                    switch cue.body {
                    case .text(let string):
                        body = .text(CoreModels.SubtitleText(string))
                    case .image(let image):
                        body = .image(CoreModels.SubtitleImage(
                            cgImage: image.cgImage,
                            normalizedRect: image.position
                        ))
                    }
                    return CoreModels.SubtitleCue(
                        id: cue.id,
                        start: cue.startTime,
                        end: cue.endTime,
                        body: body
                    )
                }
                self.onSecondarySubtitleCues?(mapped)
            }
            .store(in: &cancellables)
    }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                self?.onProgress?()
            }
        }
    }

    private func syncTracks() {
        audioTracks = engine.audioTracks.map { track in
            MediaTrack(
                id: track.id,
                kind: .audio,
                displayTitle: track.name,
                language: track.language,
                codec: track.codec,
                isDefault: track.isDefault,
                isForced: track.isForced,
                channels: track.channels > 0 ? track.channels : nil,
                isAtmos: track.isAtmos,
                isHearingImpaired: track.isHearingImpaired,
                isCommentary: track.isCommentary
            )
        }
        subtitleTracks = engine.subtitleTracks.map { track in
            MediaTrack(
                id: track.id,
                kind: .subtitle,
                displayTitle: track.name,
                language: track.language,
                codec: track.codec,
                isDefault: track.isDefault,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                isCommentary: track.isCommentary
                // NOTE: `isImageBasedSubtitle` is intentionally left at its
                // default (false) here. The menu's "(PGS)" format hint is derived
                // from `codec` instead, so labeling is accurate without changing
                // default-subtitle routing (which keys off this flag). Flipping it
                // to true belongs with the bitmap-through-overlay work, not here.
            )
        }
        // Tracks arrive asynchronously (Combine) after `loadTrackOptions()` has
        // already run once at playResolved, so tell the VM to rebuild the menu now
        // that the lists are populated — otherwise the subtitle/audio menu is
        // empty for the whole session.
        onTracksChanged?()
    }
}

// MARK: - Factory

public enum PlozzigenVideoEngineFactory {
    @MainActor
    public static func makeEngine() -> (any VideoEngine)? {
        try? PlozzigenVideoEngine()
    }
}
#endif
