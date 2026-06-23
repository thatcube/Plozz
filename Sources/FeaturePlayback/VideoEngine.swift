#if canImport(AVFoundation)
import Foundation
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

/// The lifecycle state of a `VideoEngine`, surfaced so a view model (or UI) can
/// react without knowing the concrete engine.
public enum VideoEngineStatus: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(AppError)
}

/// Hint about how *precise* a seek needs to be. Engines use this to choose
/// between snappy keyframe seeks (great for rapid skip-coalescing where only
/// the *final* destination matters) and exact frame seeks (the committed
/// scrub-bar release that has to land precisely where the user dropped it).
public enum VideoSeekKind: Sendable {
    /// Snap to the nearest keyframe / use a generous tolerance. Intended for
    /// rapid intermediate skips that will be superseded by a later seek; the
    /// goal is to start moving frames *now* without waiting for an exact decode.
    case fast
    /// Land precisely at the requested time. Intended for committed seeks
    /// (scrub-bar release, the *last* press in a coalesced skip burst).
    case exact
}

/// What an engine can do beyond the baseline transport. Used by the player
/// options menu to hide or disable controls the active engine cannot honour
/// (e.g. AVPlayer can't shift audio/subtitle delay independently), so the UI
/// degrades gracefully per engine without lying to the viewer.
public struct PlayerEngineCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Engine can change `playbackSpeed` live without a reload.
    public static let playbackSpeed = PlayerEngineCapabilities(rawValue: 1 << 0)
    /// Engine can shift audio relative to video (A/V sync offset, seconds).
    public static let audioDelay = PlayerEngineCapabilities(rawValue: 1 << 1)
    /// Engine can shift subtitles relative to video (seconds).
    public static let subtitleDelay = PlayerEngineCapabilities(rawValue: 1 << 2)
    /// Engine can boost dialog intelligibility via an audio filter.
    public static let dialogEnhance = PlayerEngineCapabilities(rawValue: 1 << 3)
}

/// Engine-agnostic abstraction over a single playback session.
///
/// `VideoEngine` captures everything `PlayerViewModel` needs from a player while
/// hiding the concrete playback stack, so a second engine (e.g. libmpv / VLCKit)
/// can be dropped in later without touching the view model, `PlayerView`, or the
/// rest of the app. Phase 1 ships exactly one implementation,
/// `NativeVideoEngine`, which wraps `AVPlayer` with byte-for-byte the behaviour
/// the view model used to own directly.
///
/// Design contract:
///  * **`@MainActor`-isolated.** All access happens on the main actor, matching
///    the rest of the playback module.
///  * **Orchestration stays out.** The engine knows nothing about the
///    `MediaProvider`: it does not resolve `PlaybackRequest`s, report progress to
///    the server, or download subtitles. Those remain the view model's job. The
///    engine reports *when* something happens (a report cadence tick, a playback
///    failure) via `onProgress` / `onFailure`, and the view model decides what to
///    do about it (report progress, re-resolve with a server transcode, …).
///  * **View vending.** The engine vends a *bare* video-output surface via
///    `makeVideoOutputView()`, so the shared player overlay can render whichever
///    engine is active without referencing a concrete player type. Transport UI
///    lives above the engine, not inside it.
@MainActor
public protocol VideoEngine: AnyObject {
    // MARK: Lifecycle

    /// Builds and starts playback for an already-resolved stream, seeking to
    /// `startPosition` (seconds) before playing. Calling `load` again on the same
    /// engine tears down any previous session first (used by the transcode
    /// fallback, which re-resolves and reloads).
    func load(request: PlaybackRequest, startPosition: TimeInterval) async

    /// Resumes playback.
    func play()

    /// Pauses playback.
    func pause()

    /// Seeks to `seconds`, clamped into the playable range.
    func seek(to seconds: TimeInterval) async

    /// Seeks to `seconds` with a hint about precision. Engines that don't
    /// distinguish kinds simply forward to `seek(to:)` (see the default impl).
    /// This is what the seek-coordinator uses: rapid intermediate presses go
    /// through `.fast` (keyframe / loose tolerance) so they don't block the
    /// next press, and the final settled target goes through `.exact`.
    func seek(to seconds: TimeInterval, kind: VideoSeekKind) async

    /// Stops playback and releases all engine resources. After `stop()` the
    /// engine is inert until `load` is called again.
    func stop()

    // MARK: Live tunables

    /// What this engine supports beyond baseline transport. The options menu
    /// reads this to hide controls the active engine can't honour.
    var capabilities: PlayerEngineCapabilities { get }

    /// Sets the playback speed multiplier (`1.0` == normal). No-op when the
    /// engine doesn't advertise `.playbackSpeed`.
    func setPlaybackSpeed(_ rate: Double)

    /// Shifts audio relative to video by `seconds` (positive = audio later,
    /// negative = audio earlier). No-op when the engine doesn't advertise
    /// `.audioDelay`.
    func setAudioDelay(_ seconds: TimeInterval)

    /// Shifts subtitles relative to video by `seconds` (positive = subs later,
    /// negative = subs earlier). No-op when the engine doesn't advertise
    /// `.subtitleDelay`.
    func setSubtitleDelay(_ seconds: TimeInterval)

    /// Enables or disables an engine-side dialog-enhancement audio filter.
    /// No-op when the engine doesn't advertise `.dialogEnhance`.
    func setDialogEnhanceEnabled(_ enabled: Bool)

    // MARK: Observable state

    /// A short, human-readable name for the concrete engine (e.g. `AVPlayer`,
    /// `VLCKit`, `mpv`), surfaced in the diagnostics overlay so the user can see
    /// which engine is actually decoding the stream. Defaulted (see the protocol
    /// extension) so engines that don't override it report a generic label.
    var displayName: String { get }

    /// The engine's current lifecycle state.
    var status: VideoEngineStatus { get }

    /// Whether playback is currently paused.
    var isPaused: Bool { get }

    /// Whether the engine is **actively presenting moving video right now** and
    /// therefore the display must be kept awake (screensaver / Apple TV sleep
    /// suppressed). This is stricter than `!isPaused`: it is `true` only while
    /// frames are genuinely advancing, so a paused, ended, or stalled stream
    /// returns `false` and lets the screensaver/sleep resume. Driving the idle
    /// timer off this (rather than user intent) keeps the behaviour identical
    /// across every engine/decoder. Defaulted to `!isPaused` (see the protocol
    /// extension) for engines that can't report a finer-grained state.
    var preventsDisplaySleep: Bool { get }

    /// Current playback position in seconds (`0` when unknown).
    var currentTime: TimeInterval { get }

    /// Total duration in seconds (`0`/non-finite when unknown or live).
    var duration: TimeInterval { get }

    /// The furthest position (seconds) observed during this session — used to
    /// resume a transcode-fallback retry where the failed attempt left off.
    var furthestObservedPosition: TimeInterval { get }

    /// Furthest buffered position (seconds) ahead of playback, used to draw the
    /// scrub bar's buffer fill. Defaulted to `0` (see the protocol extension) so
    /// an engine that can't report buffering simply opts out of the buffer fill
    /// rather than being forced to implement it.
    var bufferedPosition: TimeInterval { get }

    // MARK: Tracks

    /// Selectable audio tracks for the active stream.
    var audioTracks: [MediaTrack] { get }

    /// Selectable subtitle tracks for the active stream.
    var subtitleTracks: [MediaTrack] { get }

    /// Selects an audio track (or `nil` to leave the engine default).
    func selectAudioTrack(_ track: MediaTrack?)

    /// Selects a subtitle track (or `nil` to disable subtitles).
    func selectSubtitleTrack(_ track: MediaTrack?)

    // MARK: Orchestration callbacks

    /// Fired on the report cadence (see the implementation's interval) so the
    /// owner can report progress to the server. Invoked on the main actor.
    var onProgress: (@MainActor () -> Void)? { get set }

    /// Fired when the underlying player fails. The owner decides whether to
    /// surface the error or retry (e.g. force a server transcode). Invoked on the
    /// main actor with the engine's best classification of the failure.
    var onFailure: (@MainActor (AppError) -> Void)? { get set }

    // MARK: View

    #if canImport(UIKit)
    /// Returns the engine's **bare** video-output surface: a plain `UIView` that
    /// renders video frames and nothing else — no transport controls, no scrub
    /// bar, no track picker. The shared player overlay
    /// (`CustomPlayerContainer`) hosts this surface and layers all transport UI on
    /// top, driving the engine purely through this protocol. Implementations
    /// should vend a stable instance and keep it fed by the live stream across
    /// reloads (e.g. a transcode-fallback swap), so callers render it once and
    /// never rebuild it. The native engine returns an `AVPlayerLayer`-backed view;
    /// a future libmpv/VLCKit engine returns its own drawable from the same call,
    /// reusing the shared overlay verbatim.
    func makeVideoOutputView() -> UIView
    #endif
}

public extension VideoEngine {
    /// Default: engines that don't track buffering report no buffer fill.
    var bufferedPosition: TimeInterval { 0 }

    /// Default: a generic label for engines that don't name themselves.
    var displayName: String { "Player" }

    /// Default: keep the display awake whenever the engine isn't paused. Engines
    /// that can report a finer-grained "frames are advancing" signal (native
    /// `timeControlStatus`, mpv `eof-reached`) override this so the screensaver
    /// is also allowed at end-of-stream / during a stall, not just on pause.
    var preventsDisplaySleep: Bool { !isPaused }

    /// Default kinded-seek forwards to the unkinded variant, so existing
    /// engines that only know one seek mode keep working unchanged.
    func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        await seek(to: seconds)
    }

    /// Default: no extra tunables. Concrete engines override.
    var capabilities: PlayerEngineCapabilities { [] }
    func setPlaybackSpeed(_ rate: Double) {}
    func setAudioDelay(_ seconds: TimeInterval) {}
    func setSubtitleDelay(_ seconds: TimeInterval) {}
    func setDialogEnhanceEnabled(_ enabled: Bool) {}
}
#endif
