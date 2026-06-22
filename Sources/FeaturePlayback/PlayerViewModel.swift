#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates a single playback session over a `VideoEngine`.
///
/// The view model owns the provider-facing concerns — resolving a
/// `PlaybackRequest`, reporting progress so resume points stay in sync, the
/// automatic transcode fallback policy, and auto subtitle download — and drives a
/// `VideoEngine` (a `NativeVideoEngine` by default) for the actual playback
/// mechanics. The engine knows nothing about the provider; it reports *when*
/// something happens (a report-cadence tick, a playback failure) and the view
/// model decides what to do about it.
///
/// Responsibilities:
///  * resolve a `PlaybackRequest` via the provider;
///  * seek to the saved resume position on start (delegated to the engine);
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

    /// Shared, observable transport state for the custom player overlay. The
    /// view model writes live playback facts here; the input controller writes
    /// scrub state; the SwiftUI overlay reads.
    public let controls = PlayerControlsModel()

    private let provider: any MediaProvider
    private let itemID: String
    private let captionSettings: CaptionSettings
    /// Explicit start position (seconds) that overrides the provider's resume
    /// point when set. `nil` keeps the default behaviour (derive from the
    /// `PlaybackRequest`); `0` forces "start over"; a positive value resumes.
    private let startPositionOverride: TimeInterval?

    private let engine: any VideoEngine
    private var request: PlaybackRequest?
    private var subtitleDownloadTask: Task<Void, Never>?

    /// Guards the automatic transcode fallback so it only ever fires once — a
    /// second failure surfaces the error instead of looping.
    private var hasAttemptedTranscodeFallback = false

    /// Current in-player track-menu selection, so the menu can show a checkmark.
    /// `selectedSubtitleTrackID == nil` represents "Off".
    private var selectedAudioTrackID: Int?
    private var selectedSubtitleTrackID: Int?

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
        self.engine = NativeVideoEngine(captionSettings: captionSettings)
        configureEngineCallbacks()
    }

    private func configureEngineCallbacks() {
        engine.onProgress = { [weak self] in
            guard let self else { return }
            Task { await self.report(event: .progress, isPaused: false) }
        }
        engine.onFailure = { [weak self] error in
            guard let self else { return }
            Task { await self.handleDirectPlayFailure(error) }
        }
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
        do {
            let request = try await provider.playbackInfo(for: itemID, forceTranscode: forceTranscode)
            self.request = request
            configureControls(for: request)

            // An explicit override wins over the provider's resume point so the
            // caller can force "start over" (0) or resume from a chosen second.
            let startPosition = resumeOverride ?? startPositionOverride ?? request.startPosition

            await engine.load(request: request, startPosition: startPosition)
            phase = .ready
            await report(event: .start, isPaused: false)

            // Seed the in-player track menu from the engine's track lists (the
            // engine has already applied the user's default subtitle selection).
            loadTrackOptions()

            // Best-effort, never blocking play(): (if enabled) fetch a missing
            // subtitle in the preferred language.
            startAutoSubtitleDownloadIfNeeded(request: request)
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            phase = .failed(.unknown(""))
        }
    }

    // MARK: - Transcode fallback policy

    /// Decides what to do when the engine reports a playback failure: re-resolve
    /// forcing a server transcode (once) and resume from the last known position,
    /// or surface the error. Fires at most once; a second failure surfaces the
    /// error instead of looping.
    private func handleDirectPlayFailure(_ error: AppError) async {
        guard let request, !request.isTranscoding, !hasAttemptedTranscodeFallback else {
            // Already transcoding, already retried, or no request: surface the
            // error rather than looping.
            phase = .failed(error)
            return
        }
        hasAttemptedTranscodeFallback = true
        let resumeFrom = max(engine.furthestObservedPosition, engine.currentTime)
        PlozzLog.playback.info("Direct play failed; retrying with server transcode")
        await startPlayback(forceTranscode: true, resumeOverride: resumeFrom > 1 ? resumeFrom : nil)
    }

    // MARK: - Progress reporting

    /// Reports the current position. Best-effort: a failed report must never
    /// interrupt playback, so errors are swallowed (and never logged with data).
    private func report(event: PlaybackEvent, isPaused: Bool) async {
        guard let request else { return }
        let progress = PlaybackProgress(
            itemID: itemID,
            playSessionID: request.playSessionID,
            positionSeconds: engine.currentTime,
            isPaused: isPaused
        )
        do {
            try await provider.reportPlayback(progress, event: event)
        } catch {
            PlozzLog.playback.debug("Progress report failed (non-fatal)")
        }
    }

    // MARK: - Transport

    public func seek(to seconds: TimeInterval) async {
        controls.isSeeking = true
        // Reflect the target immediately so the bar doesn't snap backwards while
        // a (possibly slow) seek resolves.
        controls.currentSeconds = max(0, seconds)
        await engine.seek(to: seconds)
        controls.isSeeking = false
    }

    /// Toggles play/pause from the custom transport, keeping `controls` and the
    /// server report in sync.
    public func togglePlayPause() {
        setPaused(!engine.isPaused)
    }

    public func setPaused(_ paused: Bool) {
        if paused { engine.pause() } else { engine.play() }
        controls.isPaused = paused
        Task { await report(event: paused ? .pause : .unpause, isPaused: paused) }
    }

    /// Call when leaving playback: report a final stop so the server records the
    /// resume point, then tear the engine down.
    public func stop() async {
        await report(event: .stop, isPaused: true)
        subtitleDownloadTask?.cancel()
        subtitleDownloadTask = nil
        engine.stop()
    }

    // MARK: - View / diagnostics access

    /// The live `AVPlayer` backing the active (native) engine, exposed for the
    /// AVFoundation-specific diagnostics sampler and the system player view.
    /// Returns `nil` for a non-AVFoundation engine (diagnostics is best-effort).
    public var player: AVPlayer? { (engine as? NativeVideoEngine)?.underlyingPlayer }

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

    /// Scrubbing-preview thumbnails for the playing item, if the server has them.
    public var trickplay: TrickplayManifest? { request?.trickplay }

    /// The active engine, exposed so the shared transport overlay can drive
    /// playback (play/pause/seek/state/tracks) and host the engine's bare video
    /// surface — without knowing the concrete engine type.
    public var videoEngine: any VideoEngine { engine }

    // MARK: - Custom transport configuration

    /// Seeds the transport overlay with title/subtitle/duration facts when a
    /// stream resolves, so the controls are correct from the first frame.
    private func configureControls(for request: PlaybackRequest) {
        controls.title = request.item.title
        controls.subtitle = Self.subtitleText(for: request.item)
        controls.hasTrickplay = request.trickplay?.isUsable ?? false
        controls.duration = request.item.runtime ?? 0
        controls.currentSeconds = 0
        controls.bufferedSeconds = 0
        controls.isScrubbing = false
        controls.previewImage = nil
        controls.isPaused = false
    }

    /// A short secondary line for the transport bar (series · SxEx for episodes).
    private static func subtitleText(for item: MediaItem) -> String {
        var parts: [String] = []
        if let parent = item.parentTitle, !parent.isEmpty { parts.append(parent) }
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            parts.append("S\(season)E\(episode)")
        } else if let episode = item.episodeNumber {
            parts.append("Episode \(episode)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Track selection (custom player menu)

    /// Publishes the engine's audio/subtitle track lists into `controls` for the
    /// in-player track menu. Switching is routed back through the engine so the
    /// menu behaves identically across engines.
    private func loadTrackOptions() {
        let audio = engine.audioTracks
        if selectedAudioTrackID == nil {
            selectedAudioTrackID = audio.first(where: { $0.isDefault })?.id ?? audio.first?.id
        }
        controls.audioOptions = audio.map { track in
            PlayerTrackOption(id: track.id, title: track.displayTitle, isSelected: track.id == selectedAudioTrackID)
        }

        let subtitles = engine.subtitleTracks
        if subtitles.isEmpty {
            controls.subtitleOptions = []
        } else {
            var options = [PlayerTrackOption(id: PlayerTrackOption.offID, title: "Off", isSelected: selectedSubtitleTrackID == nil)]
            options.append(contentsOf: subtitles.map { track in
                PlayerTrackOption(id: track.id, title: track.displayTitle, isSelected: track.id == selectedSubtitleTrackID)
            })
            controls.subtitleOptions = options
        }
    }

    /// Selects an audio track from the menu, routed through the engine.
    public func selectAudioOption(id: Int) {
        guard let track = engine.audioTracks.first(where: { $0.id == id }) else { return }
        engine.selectAudioTrack(track)
        selectedAudioTrackID = id
        loadTrackOptions()
    }

    /// Selects a subtitle track, or turns subtitles off (`PlayerTrackOption.offID`).
    public func selectSubtitleOption(id: Int) {
        if id == PlayerTrackOption.offID {
            engine.selectSubtitleTrack(nil)
            selectedSubtitleTrackID = nil
        } else if let track = engine.subtitleTracks.first(where: { $0.id == id }) {
            engine.selectSubtitleTrack(track)
            selectedSubtitleTrackID = id
        }
        loadTrackOptions()
    }

    // MARK: - Auto subtitle download

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
