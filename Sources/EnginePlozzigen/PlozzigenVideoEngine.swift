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
        guard PlaybackTrace.enabled else { return }
        EngineLog.handler = { line in
            PlaybackTrace.note("AE " + line)
        }
    }

    // MARK: - VideoEngine Lifecycle

    public func load(request: PlaybackRequest, startPosition: TimeInterval) async {
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
            // Guard against stop() having run during the await above.
            guard status == .loading else { return }
            engine.play()
            syncTracks()
        } catch {
            let err: AppError = .unknown(error.localizedDescription)
            status = .failed(err)
            onFailure?(err)
        }
    }

    // MARK: - SMB custom source

    /// Build an SMB `MediaSource` from an `smb://user:password@host[:port]/share/path/file.ext`
    /// URL. Splits off the server + share, opens an AMSMB2-backed `SMBConnection`
    /// (NTLMv2 / guest, read-only), and wraps it in an `SMBIOReader` for the engine.
    private func makeSMBSource(from url: URL) async throws -> MediaSource {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host, !host.isEmpty else {
            throw AppError.unknown("Malformed SMB URL")
        }
        var serverComps = URLComponents()
        serverComps.scheme = "smb"
        serverComps.host = host
        serverComps.port = comps.port
        guard let server = serverComps.url else {
            throw AppError.unknown("Malformed SMB server URL")
        }
        // /share/dir/file.ext → share = "share", path = "dir/file.ext" (AMSMB2
        // wants a share-relative forward-slash path with no leading slash).
        let parts = comps.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.removingPercentEncoding ?? String($0) }
        guard let share = parts.first, parts.count >= 2 else {
            throw AppError.unknown("SMB URL missing share or file path")
        }
        let filePath = parts.dropFirst().joined(separator: "/")
        let connection = try await SMBConnection.connect(
            server: server,
            share: share,
            path: filePath,
            user: comps.user ?? "",
            password: comps.password ?? ""
        )
        return .custom(SMBIOReader(source: connection), formatHint: Self.smbFormatHint(for: filePath))
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

    public func seek(to seconds: TimeInterval) async {
        await engine.seek(to: seconds)
    }

    public func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        PlaybackTrace.note("engine.seek BEGIN target=\(String(format: "%.2f", seconds)) kind=\(kind) state=\(engine.state) curr=\(String(format: "%.2f", currentTime)) dur=\(String(format: "%.2f", duration))")
        await engine.seek(to: seconds)
        PlaybackTrace.note("engine.seek END   target=\(String(format: "%.2f", seconds)) state=\(engine.state) curr=\(String(format: "%.2f", currentTime))")
    }

    public func stop() {
        progressTimer?.cancel()
        progressTimer = nil
        engine.stop()
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

    private func observeEngine() {
        // State → status/isPaused/onEnded/onFailure
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
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
                    self.status = .failed(err)
                    self.onFailure?(err)
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
