#if canImport(VLCKitSPM) && canImport(UIKit)
import Foundation
import UIKit
import CoreModels
import FeaturePlayback
import VLCKitSPM

/// VLCKit-backed implementation of `VideoEngine`.
///
/// This is the *second* engine in Plozz's dual-engine playback stack. Where
/// `NativeVideoEngine` wraps `AVPlayer` (the default), `VLCKitVideoEngine` wraps
/// `VLCMediaPlayer` so the app CAN decode containers and codecs AVPlayer cannot
/// demux or decode on-device (MKV, DTS / DTS-HD / TrueHD, and assorted odd
/// codecs). It maps `VLCMediaPlayer` onto the engine-agnostic `VideoEngine`
/// contract: lifecycle (`load`/`play`/`pause`/`seek`/`stop`), observable
/// position/duration/state, audio + subtitle track selection, the progress /
/// failure callbacks, and a vended **bare video-output `UIView`** (VLCKit's
/// drawable) — NO transport controls. A shared, engine-agnostic scrubbing /
/// transport overlay hosts that surface and drives the engine purely through
/// this protocol, so the VLCKit engine builds no player UI of its own.
///
/// Engine *routing* (deciding when to use this engine instead of the native one)
/// is intentionally NOT wired here — the app's default behaviour stays on
/// `NativeVideoEngine`. A later phase selects this engine via
/// ``VLCKitVideoEngineFactory`` (or the public initializer).
///
/// > Note: This module depends on `FeaturePlayback` solely to *see* the
/// > `VideoEngine` protocol; `FeaturePlayback` never imports this module, so
/// > there is no dependency cycle. The engine's only view surface is
/// > `makeVideoOutputView()`, which returns the bare VLCKit drawable `UIView`;
/// > the shared scrubbing / transport overlay supplies all chrome.
///
/// Design notes:
///  * **`@MainActor`-isolated**, matching the protocol and the rest of playback.
///    `VLCMediaPlayerDelegate` callbacks arrive on the main thread, so the
///    delegate methods are `nonisolated` and immediately re-enter the main actor
///    via `MainActor.assumeIsolated`.
///  * **Orchestration stays out.** Like the native engine, it knows nothing
///    about `MediaProvider`; it reports a 10s progress cadence and playback
///    failures through `onProgress` / `onFailure` and lets the owner decide.
///  * **Track lists mirror the provider.** `audioTracks` / `subtitleTracks`
///    surface the provider-reported tracks carried on the `PlaybackRequest`
///    (same as the native engine), so the UI shows a stable, labelled list.
///    Selection best-effort maps a `MediaTrack.id` onto VLC's own track indexes.
@MainActor
public final class VLCKitVideoEngine: NSObject, VideoEngine {
    // MARK: Observable state

    public private(set) var status: VideoEngineStatus = .idle
    public private(set) var isPaused: Bool = false

    public let displayName = "VLCKit"

    public var currentTime: TimeInterval {
        guard let player = mediaPlayer else { return 0 }
        return max(0, TimeInterval(player.time.intValue) / 1000)
    }

    public var duration: TimeInterval {
        guard let length = mediaPlayer?.media?.length else { return 0 }
        return max(0, TimeInterval(length.intValue) / 1000)
    }

    public private(set) var furthestObservedPosition: TimeInterval = 0

    public var audioTracks: [MediaTrack] { request?.audioTracks ?? [] }
    public var subtitleTracks: [MediaTrack] { request?.subtitleTracks ?? [] }

    // MARK: Orchestration callbacks

    public var onProgress: (@MainActor () -> Void)?
    public var onFailure: (@MainActor (AppError) -> Void)?

    // MARK: Configuration

    /// Extra libvlc options passed to `VLCMediaPlayer` (e.g. verbosity, caching).
    /// Empty by default; a later phase can tune these for the Apple TV.
    private let options: [String]

    /// The user's caption preferences, used to choose the default subtitle once
    /// VLC has parsed the media's tracks (VLCKit exposes no tracks until then).
    private let captionSettings: CaptionSettings

    // MARK: Private playback state

    private var mediaPlayer: VLCMediaPlayer?
    private var request: PlaybackRequest?
    private let reportInterval: TimeInterval = 10
    private var lastReportedSecond: Int = -1
    private var hasReachedPlaying = false

    /// What subtitle the engine should display. `.auto` applies the user's
    /// caption-settings default once tracks are known; `.explicit` is a manual
    /// pick (a `nil` track means "off"). Resolved lazily because VLC only exposes
    /// its track list after parsing the media.
    private enum SubtitleIntent {
        case auto
        case explicit(MediaTrack?)
    }
    private var subtitleIntent: SubtitleIntent = .auto
    private var hasResolvedSubtitleIntent = false
    /// A single, stable bare `UIView` handed to VLCKit as its drawable. VLC
    /// renders video into it; the shared transport overlay hosts it. Reused
    /// across reloads so the SwiftUI layer never has to rebuild it.
    private var outputView: UIView?

    /// Creates a VLCKit engine. `options` are forwarded to `VLCMediaPlayer` as
    /// libvlc arguments; the default is none. `captionSettings` drives the
    /// default subtitle chosen once VLC parses the media.
    public init(captionSettings: CaptionSettings = .default, options: [String] = []) {
        self.captionSettings = captionSettings
        self.options = options
        super.init()
    }

    /// The live `VLCMediaPlayer`, exposed for VLC-specific diagnostics. Engine-
    /// agnostic callers must not depend on this.
    public var underlyingPlayer: VLCMediaPlayer? { mediaPlayer }

    // MARK: - Lifecycle

    public func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        status = .loading
        // Tear down any previous player (e.g. a failed direct-play attempt being
        // retried) without reporting a stop.
        teardownPlayer()

        self.request = request
        hasReachedPlaying = false
        lastReportedSecond = -1
        subtitleIntent = .auto
        hasResolvedSubtitleIntent = false

        let player = options.isEmpty ? VLCMediaPlayer() : VLCMediaPlayer(options: options)
        player.delegate = self
        player.drawable = outputView
        player.media = VLCMedia(url: request.streamURL)
        mediaPlayer = player

        furthestObservedPosition = max(furthestObservedPosition, startPosition)

        player.play()

        if startPosition > 1 {
            seekPlayer(player, to: startPosition)
        }

        isPaused = false
    }

    public func play() {
        guard let player = mediaPlayer else { return }
        player.play()
        isPaused = false
    }

    public func pause() {
        guard let player = mediaPlayer else { return }
        // VLCMediaPlayer's `pause` toggles; gate on the live state so a stray
        // call can't accidentally resume playback.
        if player.isPlaying {
            player.pause()
            isPaused = true
        }
    }

    public func stop() {
        teardownPlayer()
        status = .idle
    }

    private func teardownPlayer() {
        if let player = mediaPlayer {
            player.delegate = nil
            player.stop()
        }
        mediaPlayer = nil
        lastReportedSecond = -1
    }

    // MARK: - Seeking

    public func seek(to seconds: TimeInterval) async {
        guard let player = mediaPlayer else { return }
        seekPlayer(player, to: seconds)
    }

    private func seekPlayer(_ player: VLCMediaPlayer, to seconds: TimeInterval) {
        let clamped = max(0, seconds)
        let milliseconds = Int32(clamping: Int(clamped * 1000))
        player.time = VLCTime(int: milliseconds)
        furthestObservedPosition = max(furthestObservedPosition, clamped)
    }

    // MARK: - Track selection

    /// Best-effort audio selection: maps the provider track onto VLC's own audio
    /// track by ordinal position (VLC lists tracks in container order, matching
    /// the provider). `nil` leaves VLC's default selection untouched.
    public func selectAudioTrack(_ track: MediaTrack?) {
        guard let player = mediaPlayer, let track else { return }
        let providerAudio = (request?.audioTracks ?? []).filter { $0.kind == .audio }
        let vlcIndexes = realTrackIndexes(player.audioTrackIndexes)
        if let vlc = mapOrdinal(track: track, providerTracks: providerAudio, vlcIndexes: vlcIndexes) {
            player.currentAudioTrackIndex = vlc
        }
    }

    /// Manual subtitle selection: records the intent and applies it as soon as
    /// VLC has parsed the subtitle tracks. `nil` disables subtitles.
    public func selectSubtitleTrack(_ track: MediaTrack?) {
        subtitleIntent = .explicit(track)
        hasResolvedSubtitleIntent = false
        resolveSubtitleIntent()
    }

    /// Resolves the pending ``subtitleIntent`` against VLC's parsed track list.
    /// No-ops (and stays pending) until VLC has exposed its subtitle indexes, so
    /// a selection requested during `load()` lands once parsing completes. The
    /// `.auto` intent applies the user's caption-settings default exactly once.
    private func resolveSubtitleIntent() {
        guard !hasResolvedSubtitleIntent, let player = mediaPlayer else { return }
        let providerSubs = (request?.subtitleTracks ?? []).filter { $0.kind == .subtitle }
        let vlcIndexes = realTrackIndexes(player.videoSubTitlesIndexes)

        switch subtitleIntent {
        case .auto:
            // Nothing to choose from → done. Otherwise wait for VLC to parse.
            guard !providerSubs.isEmpty else { hasResolvedSubtitleIntent = true; return }
            guard !vlcIndexes.isEmpty else { return }
            let chosen = providerSubs.defaultSubtitleSelection(
                mode: captionSettings.subtitleMode,
                preferredLanguage: captionSettings.resolvedPreferredLanguage)
            applySubtitle(chosen, providerSubs: providerSubs, vlcIndexes: vlcIndexes, player: player)
            hasResolvedSubtitleIntent = true

        case .explicit(let track):
            guard let track else {
                player.currentVideoSubTitleIndex = -1
                hasResolvedSubtitleIntent = true
                return
            }
            guard !vlcIndexes.isEmpty else { return }
            applySubtitle(track, providerSubs: providerSubs, vlcIndexes: vlcIndexes, player: player)
            hasResolvedSubtitleIntent = true
        }
    }

    private func applySubtitle(
        _ track: MediaTrack?,
        providerSubs: [MediaTrack],
        vlcIndexes: [Int],
        player: VLCMediaPlayer
    ) {
        guard let track else { player.currentVideoSubTitleIndex = -1; return }
        if let vlc = mapOrdinal(track: track, providerTracks: providerSubs, vlcIndexes: vlcIndexes) {
            player.currentVideoSubTitleIndex = vlc
        }
    }

    /// VLC's track-index arrays lead with a `-1` "Disable" pseudo-track; strip it
    /// to get the real tracks in container order.
    private func realTrackIndexes(_ raw: [Any]?) -> [Int] {
        (raw ?? []).compactMap { ($0 as? NSNumber)?.intValue }.filter { $0 >= 0 }
    }

    /// Maps a provider track to VLC's own track index by **ordinal position**
    /// among same-kind tracks — robust because VLC and the provider both list
    /// embedded tracks in container order, even though their numeric ids differ.
    /// Falls back to a direct id match when the counts disagree (e.g. an external
    /// sidecar track shifts the alignment).
    private func mapOrdinal(track: MediaTrack, providerTracks: [MediaTrack], vlcIndexes: [Int]) -> Int32? {
        if let pos = providerTracks.firstIndex(where: { $0.id == track.id }),
           providerTracks.count == vlcIndexes.count, vlcIndexes.indices.contains(pos) {
            return Int32(vlcIndexes[pos])
        }
        if vlcIndexes.contains(track.id) { return Int32(track.id) }
        return nil
    }

    // MARK: - View

    /// Vends the engine's **bare** video-output surface: a plain `UIView` used as
    /// VLCKit's `drawable`, with no transport controls. The shared engine-agnostic
    /// scrubbing / transport overlay hosts this view and drives the engine through
    /// the `VideoEngine` protocol (it polls `currentTime` / `duration` / `isPaused`
    /// and calls `play` / `pause` / `seek` / track selection). The instance is
    /// stable across `load()` / `stop()` cycles — each new `VLCMediaPlayer` is
    /// re-pointed at the same drawable — so the SwiftUI layer never rebuilds it.
    public func makeVideoOutputView() -> UIView {
        ensureOutputView()
    }

    @discardableResult
    private func ensureOutputView() -> UIView {
        if let existing = outputView { return existing }
        let view = UIView()
        view.backgroundColor = .black
        outputView = view
        // Point any already-live player at the freshly created surface.
        mediaPlayer?.drawable = view
        return view
    }

    // MARK: - State handling

    private func handleStateChanged() {
        guard let player = mediaPlayer else { return }
        switch player.state {
        case .opening, .buffering, .esAdded:
            if status != .ready { status = .loading }
            // Subtitle/audio tracks appear as elementary streams are added —
            // try to apply the pending selection as soon as they exist.
            resolveSubtitleIntent()
        case .playing:
            hasReachedPlaying = true
            status = .ready
            isPaused = false
            // By now VLC has parsed the media; apply the default/pending subtitle.
            resolveSubtitleIntent()
        case .paused:
            isPaused = true
        case .error:
            status = .failed(.invalidResponse)
            onFailure?(.invalidResponse)
        case .stopped, .ended:
            break
        @unknown default:
            break
        }
    }

    private func handleTimeChanged() {
        let seconds = currentTime
        if seconds.isFinite { furthestObservedPosition = max(furthestObservedPosition, seconds) }
        let whole = Int(seconds)
        guard whole != lastReportedSecond, whole % Int(reportInterval) == 0 else { return }
        lastReportedSecond = whole
        onProgress?()
    }
}

// MARK: - VLCMediaPlayerDelegate

// VLCKit delivers these callbacks on the main thread; re-enter the main actor to
// touch isolated state. (`MainActor.assumeIsolated` is sound here because the
// thread is already the main thread.)
extension VLCKitVideoEngine: VLCMediaPlayerDelegate {
    nonisolated public func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { self.handleStateChanged() }
    }

    nonisolated public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { self.handleTimeChanged() }
    }
}

// MARK: - Factory

/// A tiny factory so a later phase (engine routing) can construct the VLCKit
/// engine. The app's default engine remains `NativeVideoEngine`; nothing here
/// changes that until routing is wired.
public enum VLCKitVideoEngineFactory {
    /// Builds a VLCKit-backed `VideoEngine`.
    @MainActor
    public static func makeEngine(
        captionSettings: CaptionSettings = .default,
        options: [String] = []
    ) -> any VideoEngine {
        VLCKitVideoEngine(captionSettings: captionSettings, options: options)
    }
}
#endif
