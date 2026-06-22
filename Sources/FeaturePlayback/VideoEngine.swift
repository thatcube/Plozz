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

    /// Stops playback and releases all engine resources. After `stop()` the
    /// engine is inert until `load` is called again.
    func stop()

    // MARK: Observable state

    /// The engine's current lifecycle state.
    var status: VideoEngineStatus { get }

    /// Whether playback is currently paused.
    var isPaused: Bool { get }

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
}
#endif
