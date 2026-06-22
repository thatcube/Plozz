#if canImport(Libmpv) && canImport(UIKit)
import Foundation
import UIKit
import CoreModels
import FeaturePlayback
import Libmpv

/// libmpv-backed implementation of `VideoEngine`.
///
/// This is the **third** engine in Plozz's playback stack, alongside
/// `NativeVideoEngine` (AVPlayer, the default) and `VLCKitVideoEngine`. Where
/// VLCKit decodes the exotic containers/codecs AVPlayer can't, `MPVVideoEngine`
/// wraps **libmpv** to do the same on-device decode (MKV / DTS / DTS-HD / TrueHD
/// / odd codecs) through a modern Metal render path with libplacebo HDR
/// tone-mapping. It maps libmpv onto the engine-agnostic `VideoEngine` contract:
/// lifecycle (`load`/`play`/`pause`/`seek`/`stop`), observable position /
/// duration / state, audio + subtitle track selection, the progress / failure
/// callbacks, and a vended **bare** video-output `UIView` (the `CAMetalLayer`
/// libmpv renders into) — NO transport chrome. The shared transport overlay hosts
/// that surface and drives the engine purely through this protocol.
///
/// ### Render path
/// libmpv renders directly into a `CAMetalLayer` handed to it as the integer
/// `wid` option, with `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenvk`
/// (Vulkan → MoltenVK → Metal) and `hwdec=videotoolbox` for hardware HEVC/H.264.
/// This is the path MPVKit's own reference tvOS player uses and is preferred over
/// the `mpv_render_context` OpenGL API (OpenGLES is deprecated on tvOS) and the
/// software (`MPV_RENDER_API_TYPE_SW`) fallback. It gives the best quality —
/// `gpu-next` + libplacebo HDR tone-mapping — for free.
///
/// ### Threading
/// `@MainActor`-isolated like the protocol. All libmpv C interop is funnelled
/// through ``MPVClient`` (thread-safe, `Sendable`). libmpv's wakeup callback fires
/// on an arbitrary thread; events are drained on a background queue and each
/// `Sendable` ``MPVEvent`` is marshalled back onto the main actor (FIFO) before
/// touching engine state.
///
/// ### Orchestration
/// Like the other engines it knows nothing about `MediaProvider`: it reports a
/// ~10s progress cadence and playback failures through `onProgress` / `onFailure`
/// and lets the owner decide. Engine *routing* is intentionally NOT wired here;
/// the app default stays on `NativeVideoEngine`.
@MainActor
public final class MPVVideoEngine: NSObject, VideoEngine {
    // MARK: Observable state

    public private(set) var status: VideoEngineStatus = .idle
    public private(set) var isPaused: Bool = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var furthestObservedPosition: TimeInterval = 0

    public var audioTracks: [MediaTrack] { request?.audioTracks ?? [] }
    public var subtitleTracks: [MediaTrack] { request?.subtitleTracks ?? [] }

    // MARK: Orchestration callbacks

    public var onProgress: (@MainActor () -> Void)?
    public var onFailure: (@MainActor (AppError) -> Void)?

    // MARK: Configuration

    /// Extra `mpv_set_option_string` pairs applied before `mpv_initialize`
    /// (e.g. cache tuning). Empty by default; a later phase can tune these.
    private let extraOptions: [String: String]

    // MARK: Private state

    private let client = MPVClient()
    /// The single, stable `CAMetalLayer` libmpv draws into. Created eagerly so its
    /// pointer can be handed to mpv as `wid` even before the hosting view exists,
    /// and reused across `load()` / `stop()` so the SwiftUI layer never rebuilds.
    private let metalLayer = MPVMetalLayer()
    private var outputView: MPVRenderView?

    private var request: PlaybackRequest?
    private let reportInterval: TimeInterval = 10
    private var lastReportedSecond: Int = -1
    private var hasFailed = false

    /// The opaque, *retained* `self` pointer handed to mpv's wakeup callback.
    /// Retaining (rather than passing unretained) guarantees the engine can't be
    /// deallocated while a wakeup is mid-flight on another thread; the matching
    /// `release` happens in `teardownClient()` after the handle (and its callback)
    /// are gone.
    private var wakeupCtx: UnsafeMutableRawPointer?

    /// Background queue that drains the mpv event loop (kept off the main actor).
    private let eventQueue = DispatchQueue(label: "com.thatcube.Plozz.mpv.events", qos: .userInitiated)

    public init(extraOptions: [String: String] = [:]) {
        self.extraOptions = extraOptions
        super.init()
    }

    deinit {
        // Safety net. With a retained wakeup ctx the engine normally can't reach
        // deinit until `teardownClient()` has released that ref (after destroying
        // the handle), so by here the handle is already gone — this `destroy()` is
        // an idempotent no-op that just guards the (impossible-in-normal-flow)
        // path where a handle was created but never torn down.
        client.destroy()
    }

    // MARK: - Lifecycle

    public func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        status = .loading
        teardownClient()

        self.request = request
        hasFailed = false
        isPaused = false
        currentTime = 0
        duration = 0
        lastReportedSecond = -1
        furthestObservedPosition = max(furthestObservedPosition, startPosition)

        guard client.create() else {
            fail(.unknown("mpv: failed to create player context"))
            return
        }

        client.requestLogMessages("no")

        // Hand mpv the metal layer as its render surface (must precede init).
        let layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        client.setWindowID(layerPointer)

        // Render + decode configuration (mirrors MPVKit's reference tvOS player).
        client.setOptionString("vo", "gpu-next")
        client.setOptionString("gpu-api", "vulkan")
        client.setOptionString("gpu-context", "moltenvk")
        client.setOptionString("hwdec", "videotoolbox")
        client.setOptionString("video-rotate", "no")
        // Match-OS-language subtitle/audio defaults, harmless when tracks are
        // explicitly selected later by the view model.
        client.setOptionString("subs-match-os-language", "yes")
        client.setOptionString("subs-fallback", "yes")
        for (key, value) in extraOptions {
            client.setOptionString(key, value)
        }

        // Wakeup callback + property observation (before init so nothing is missed).
        // Retain `self` for mpv; balanced by the release in `teardownClient()`.
        let ctx = Unmanaged.passRetained(self).toOpaque()
        wakeupCtx = ctx
        client.setWakeup(ctx: ctx, callback: mpvWakeupCallback)
        client.observeDouble(MPVProperty.timePos)
        client.observeDouble(MPVProperty.duration)
        client.observeFlag(MPVProperty.pause)
        client.observeFlag(MPVProperty.eofReached)

        guard client.initialize() >= 0 else {
            teardownClient()
            fail(.unknown("mpv: failed to initialize player"))
            return
        }

        // Resume via a per-file `start=` option so playback opens at the right
        // spot without a separate post-load seek.
        var args = ["loadfile", request.streamURL.absoluteString, "replace"]
        if startPosition > 1 {
            args.append("-1")
            args.append("start=\(Int(startPosition))")
        }
        client.command(args)
    }

    public func play() {
        guard client.isAlive else { return }
        client.setFlag(MPVProperty.pause, false)
        isPaused = false
    }

    public func pause() {
        guard client.isAlive else { return }
        client.setFlag(MPVProperty.pause, true)
        isPaused = true
    }

    public func stop() {
        teardownClient()
        status = .idle
    }

    private func teardownClient() {
        if client.isAlive {
            client.destroy()
        }
        // Balance the `passRetained(self)` from `load()`. `destroy()` has already
        // cleared the wakeup callback, so no further wakeup can resurrect `self`
        // after this release.
        if let ctx = wakeupCtx {
            wakeupCtx = nil
            Unmanaged<MPVVideoEngine>.fromOpaque(ctx).release()
        }
        lastReportedSecond = -1
    }

    // MARK: - Seeking

    public func seek(to seconds: TimeInterval) async {
        guard client.isAlive else { return }
        let clamped = max(0, seconds)
        client.command(["seek", "\(clamped)", "absolute", "exact"])
        furthestObservedPosition = max(furthestObservedPosition, clamped)
    }

    // MARK: - Track selection

    /// Best-effort audio selection. The provider's `MediaTrack.id` is the source
    /// file's absolute stream index, which equals mpv's `track-list/N/ff-index`;
    /// we match on that and set mpv's own `aid`. `nil` leaves mpv's default.
    public func selectAudioTrack(_ track: MediaTrack?) {
        guard client.isAlive, let track else { return }
        if let id = mpvTrackID(ffIndex: track.id, type: "audio") {
            client.setPropertyString("aid", "\(id)")
        }
    }

    /// Best-effort subtitle selection. `nil` disables subtitles (`sid=no`);
    /// otherwise maps the provider stream index onto mpv's `sid` via `ff-index`.
    public func selectSubtitleTrack(_ track: MediaTrack?) {
        guard client.isAlive else { return }
        guard let track else {
            client.setPropertyString("sid", "no")
            return
        }
        if let id = mpvTrackID(ffIndex: track.id, type: "sub") {
            client.setPropertyString("sid", "\(id)")
        }
    }

    /// Looks up mpv's internal track id for a given source `ff-index` + type
    /// (`audio` / `sub`). Returns `nil` when mpv hasn't surfaced a matching track.
    private func mpvTrackID(ffIndex: Int, type: String) -> Int64? {
        guard let count = client.getInt("track-list/count") else { return nil }
        for i in 0..<count {
            guard client.getString("track-list/\(i)/type") == type else { continue }
            if let ff = client.getInt("track-list/\(i)/ff-index"), Int(ff) == ffIndex {
                return client.getInt("track-list/\(i)/id")
            }
        }
        return nil
    }

    // MARK: - View

    public func makeVideoOutputView() -> UIView {
        if let outputView { return outputView }
        let view = MPVRenderView(metalLayer: metalLayer)
        outputView = view
        return view
    }

    // MARK: - Event handling (main actor)

    /// Called from the background drain queue's main-actor hop for each event.
    fileprivate func apply(_ event: MPVEvent) {
        switch event {
        case .fileLoaded:
            duration = client.getDouble(MPVProperty.duration)
            status = .ready
        case .propertyChanged(let name):
            handleProperty(name)
        case .endFile(let isError):
            if isError { fail(.invalidResponse) }
        case .shutdown:
            status = .idle
        }
    }

    private func handleProperty(_ name: String) {
        switch name {
        case MPVProperty.timePos:
            let seconds = client.getDouble(MPVProperty.timePos)
            guard seconds.isFinite else { return }
            currentTime = max(0, seconds)
            furthestObservedPosition = max(furthestObservedPosition, currentTime)
            reportProgressIfNeeded(at: currentTime)
        case MPVProperty.duration:
            let value = client.getDouble(MPVProperty.duration)
            if value.isFinite { duration = max(0, value) }
        case MPVProperty.pause:
            isPaused = client.getFlag(MPVProperty.pause)
        case MPVProperty.eofReached:
            // `eof-reached` flips true at a clean end-of-stream; treated as a
            // benign stop (the owner reads `currentTime`/`duration`), not a fail.
            break
        default:
            break
        }
    }

    private func reportProgressIfNeeded(at seconds: TimeInterval) {
        let whole = Int(seconds)
        guard whole != lastReportedSecond, whole % Int(reportInterval) == 0 else { return }
        lastReportedSecond = whole
        onProgress?()
    }

    private func fail(_ error: AppError) {
        guard !hasFailed else { return }
        hasFailed = true
        status = .failed(error)
        onFailure?(error)
    }

    // MARK: - Event pump (nonisolated; called from the C wakeup callback)

    /// Schedules a drain of the mpv event queue on the background queue. Safe to
    /// call from any thread — that's why it's `nonisolated`.
    nonisolated fileprivate func scheduleEventDrain() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            self.client.drainEvents { event in
                // Hop to the main actor in FIFO order before touching state.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.apply(event) }
                }
            }
        }
    }
}

// MARK: - mpv property names

private enum MPVProperty {
    static let timePos = "time-pos"
    static let duration = "duration"
    static let pause = "pause"
    static let eofReached = "eof-reached"
}

// MARK: - C wakeup callback

/// Global C callback registered with `mpv_set_wakeup_callback`. `ctx` is the
/// retained `MPVVideoEngine` pointer (kept alive by `wakeupCtx`); we take it
/// *unretained* here since the engine owns that +1, then just nudge a drain.
private let mpvWakeupCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
    guard let ctx else { return }
    let engine = Unmanaged<MPVVideoEngine>.fromOpaque(ctx).takeUnretainedValue()
    engine.scheduleEventDrain()
}

// MARK: - Factory

/// A tiny factory mirroring `VLCKitVideoEngineFactory` so a later phase (engine
/// routing) can construct the mpv engine. The app default remains
/// `NativeVideoEngine`; nothing here changes that until routing is wired.
public enum MPVVideoEngineFactory {
    @MainActor
    public static func makeEngine(extraOptions: [String: String] = [:]) -> any VideoEngine {
        MPVVideoEngine(extraOptions: extraOptions)
    }
}
#endif
