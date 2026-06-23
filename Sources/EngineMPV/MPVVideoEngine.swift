#if canImport(Libmpv) && canImport(UIKit)
import Foundation
import UIKit
import AVKit
import CoreMedia
import os
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

    public let displayName = "mpv"

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

    /// What the HDR path realized for the current stream (for diagnostics). Read
    /// it after `load()` to see the targeted mode, the surface format/colorspace,
    /// and whether a display-mode switch was requested/allowed.
    public private(set) var hdrStatus = MPVHDRStatus()

    /// A pending HDR display-mode switch awaiting a live `UIWindow`. Applied as
    /// soon as the output view is in a window; `nil` for SDR content.
    private var pendingDisplayCriteria: AVDisplayCriteria?
    /// Whether we currently hold an applied `preferredDisplayCriteria` that must
    /// be cleared on teardown so the TV isn't left stuck in a forced mode.
    private var didApplyDisplayCriteria = false
    /// The display manager we set `preferredDisplayCriteria` on. Captured at apply
    /// time so we can always clear on the *same* manager even if the output view
    /// has since left its window (otherwise the switch would leak and strand the
    /// TV in a forced mode). Weak so a dead window isn't kept alive by us.
    private weak var appliedDisplayManager: AVDisplayManager?

    private let log = Logger(subsystem: "com.thatcube.Plozz", category: "EngineMPV")

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

    /// `mpv_initialize()` must run with a real, attached render target.
    /// Wait for the mpv surface to be in a window and laid out to a non-trivial
    /// drawable size before initializing the player.
    private func waitForRenderableSurface(timeout: TimeInterval = 3) async -> Bool {
        _ = makeVideoOutputView()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let outputView {
                outputView.layoutIfNeeded()
            }
            if isRenderableSurfaceReady {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return isRenderableSurfaceReady
    }

    private var isRenderableSurfaceReady: Bool {
        guard let outputView, outputView.window != nil else { return false }
        guard metalLayer.device != nil else { return false }
        let size = metalLayer.drawableSize
        return size.width > 1 && size.height > 1
    }

    public func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        plozzTrace("MPV.load: start (startPosition=\(startPosition))")
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
        plozzTrace("MPV.load: client.create OK")

        client.requestLogMessages("no")
        let hdrMode = MPVHDR.mode(from: request.sourceMetadata?.video)

        // Hand mpv the metal layer as its render surface (must precede init).
        let layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        client.setWindowID(layerPointer)

        // Render + decode configuration (mirrors MPVKit's reference tvOS player).
        client.setOptionString("vo", "gpu-next")
        client.setOptionString("gpu-api", "vulkan")
        client.setOptionString("gpu-context", "moltenvk")
        client.setOptionString("hwdec", "videotoolbox")
        client.setOptionString("video-rotate", "no")

        // Pick surface colorimetry from source metadata.
        plozzTrace("MPV.load: hdrMode=\(hdrMode); configuring metalLayer")
        metalLayer.configure(for: hdrMode)
        plozzTrace("MPV.load: metalLayer.configure done")
        client.setOptionString("target-colorspace-hint", "yes")
        if let trc = MPVHDR.mpvTargetTRC(for: hdrMode) {
            client.setOptionString("target-trc", trc)
            client.setOptionString("target-prim", "bt.2020")
        }
        // Prepare (but don't yet apply) the tvOS display-mode switch for HDR; it
        // needs a live UIWindow and is gated to HDR content so SDR never yanks the
        // TV into HDR. Applied after init / once the view is in a window.
        pendingDisplayCriteria = MPVHDR.formatDescription(for: hdrMode, video: request.sourceMetadata?.video).map {
            AVDisplayCriteria(refreshRate: Float(request.sourceMetadata?.video?.frameRate ?? 0), formatDescription: $0)
        }

        // Match-OS-language subtitle/audio defaults, harmless when tracks are
        // explicitly selected later by the view model.
        client.setOptionString("subs-match-os-language", "yes")
        client.setOptionString("subs-fallback", "yes")
        for (key, value) in extraOptions {
            client.setOptionString(key, value)
        }

        plozzTrace("MPV.load: waiting for render surface readiness")
        guard await waitForRenderableSurface() else {
            teardownClient()
            fail(.unknown("mpv: render surface was not ready in time"))
            return
        }
        plozzTrace("MPV.load: render surface ready (window + drawable + device)")

        plozzTrace("MPV.load: calling client.initialize() NOW")

        guard client.initialize() >= 0 else {
            teardownClient()
            fail(.unknown("mpv: failed to initialize player"))
            return
        }
        // Match MPVKit's ordering: initialize first, then register wakeup /
        // observers. Registering before init has been unstable on tvOS.
        let ctx = Unmanaged.passRetained(self).toOpaque()
        wakeupCtx = ctx
        client.setWakeup(ctx: ctx, callback: mpvWakeupCallback)
        client.observeDouble(MPVProperty.timePos)
        client.observeDouble(MPVProperty.duration)
        client.observeFlag(MPVProperty.pause)
        client.observeFlag(MPVProperty.eofReached)
        plozzTrace("MPV.load: client.initialize OK; callbacks+observers set; applying display criteria")

        // Apply the HDR display switch now (the view is usually already in a
        // window during playback); otherwise it lands via `onWindowChange`.
        applyDisplayCriteriaIfPossible()
        plozzTrace("MPV.load: applyDisplayCriteriaIfPossible done; updateHDRStatus")
        updateHDRStatus(mode: hdrMode)
        plozzTrace("MPV.load: updateHDRStatus done; issuing loadfile")

        // Resume via a per-file `start=` option so playback opens at the right
        // spot without a separate post-load seek.
        var args = ["loadfile", request.streamURL.absoluteString, "replace"]
        if startPosition > 1 {
            args.append("-1")
            args.append("start=\(Int(startPosition))")
        }
        client.command(args)
        plozzTrace("MPV.load: loadfile command issued; load() returning")
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
        // Release any HDR display-mode switch so the TV isn't left stuck in a
        // forced mode after playback stops.
        clearDisplayCriteria()
        pendingDisplayCriteria = nil
        hdrStatus = MPVHDRStatus()
        lastReportedSecond = -1
    }

    // MARK: - HDR display-mode switching

    /// Applies the pending HDR `preferredDisplayCriteria` if we have one and the
    /// output view is in a window. Gated to HDR content (SDR leaves
    /// `pendingDisplayCriteria` nil), so SDR playback never switches the display.
    private func applyDisplayCriteriaIfPossible() {
        guard let criteria = pendingDisplayCriteria,
              let window = outputView?.window,
              Self.windowHasDisplayManager(window) else { return }
        let manager = window.avDisplayManager
        manager.preferredDisplayCriteria = criteria
        appliedDisplayManager = manager
        didApplyDisplayCriteria = true
        log.info("HDR: requested display-mode switch (matchingEnabled=\(manager.isDisplayCriteriaMatchingEnabled, privacy: .public))")
    }

    /// Clears our `preferredDisplayCriteria` (passing `nil` returns the display to
    /// a mode suitable for mixed/UI content). Only touches the manager if we
    /// actually applied a switch. Clears via the *captured* manager so it still
    /// works after the output view has left its window — otherwise the forced
    /// mode would leak and strand the TV.
    private func clearDisplayCriteria() {
        guard didApplyDisplayCriteria else { return }
        let resolvedManager: AVDisplayManager?
        if let applied = appliedDisplayManager {
            resolvedManager = applied
        } else if let window = outputView?.window, Self.windowHasDisplayManager(window) {
            resolvedManager = window.avDisplayManager
        } else {
            resolvedManager = nil
        }
        guard let manager = resolvedManager else {
            // No handle to the manager (window torn down before we captured it).
            // Nothing reachable to clear; drop our state so we don't loop.
            log.error("HDR: could not clear display criteria — manager unreachable")
            appliedDisplayManager = nil
            didApplyDisplayCriteria = false
            return
        }
        manager.preferredDisplayCriteria = nil
        appliedDisplayManager = nil
        didApplyDisplayCriteria = false
    }

    /// Safety net: the `avDisplayManager` accessor comes from AVKit's
    /// `UIWindow (AVAdditions)` category. If AVKit somehow isn't loaded the
    /// selector is unrecognized and accessing it would crash with
    /// `-[UIWindow avDisplayManager]: unrecognized selector` — so verify it's
    /// present first and degrade to a no-op (no HDR display switch) instead.
    private static func windowHasDisplayManager(_ window: UIWindow) -> Bool {
        window.responds(to: Selector(("avDisplayManager")))
    }

    /// Snapshots the realized HDR state for diagnostics and logs it.
    private func updateHDRStatus(mode: MPVHDRMode) {
        let info = metalLayer.realizedColorInfo
        let matchingEnabled: Bool = {
            guard let window = outputView?.window, Self.windowHasDisplayManager(window) else { return false }
            return window.avDisplayManager.isDisplayCriteriaMatchingEnabled
        }()
        hdrStatus = MPVHDRStatus(
            requestedMode: mode.rawValue,
            layerPixelFormat: info.pixelFormat,
            layerColorspace: info.colorspace,
            displaySwitchRequested: didApplyDisplayCriteria,
            displayMatchingEnabled: matchingEnabled)
        log.info("HDR status mode=\(mode.rawValue, privacy: .public) surface=\(info.pixelFormat, privacy: .public) colorspace=\(info.colorspace ?? "nil", privacy: .public) switchRequested=\(self.didApplyDisplayCriteria, privacy: .public) matchingEnabled=\(matchingEnabled, privacy: .public)")
    }

    // MARK: - Seeking

    public func seek(to seconds: TimeInterval) async {
        await seek(to: seconds, kind: .exact)
    }

    public func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        guard client.isAlive else { return }
        let clamped = max(0, seconds)
        // mpv's `keyframes` mode is dramatically faster than `exact` (a
        // refdec-then-decode walk) and is exactly what we want for the
        // intermediate frames of a rapid-skip burst: snap to the nearest
        // keyframe NOW so the on-screen position obviously moves, and let
        // the *final* (.exact) seek land precisely on release.
        let mode = kind == .fast ? "keyframes" : "exact"
        client.command(["seek", "\(clamped)", "absolute", mode])
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

    // MARK: - Live tunables

    /// mpv changes all four tunables live, with no reload, via single property
    /// writes — exactly what the options menu needs for frame-accurate feedback.
    public var capabilities: PlayerEngineCapabilities {
        [.playbackSpeed, .audioDelay, .subtitleDelay, .dialogEnhance]
    }

    public func setPlaybackSpeed(_ rate: Double) {
        guard client.isAlive else { return }
        let clamped = max(0.25, min(4.0, rate))
        client.setPropertyString("speed", String(format: "%.3f", clamped))
    }

    public func setAudioDelay(_ seconds: TimeInterval) {
        guard client.isAlive else { return }
        client.setPropertyString("audio-delay", String(format: "%.3f", seconds))
    }

    public func setSubtitleDelay(_ seconds: TimeInterval) {
        guard client.isAlive else { return }
        client.setPropertyString("sub-delay", String(format: "%.3f", seconds))
    }

    /// Toggles a labelled `dynaudnorm` audio filter that smooths the loudness
    /// curve so dialog stays audible without the surround mix peaking. We use
    /// the `@plozz-dialog` label so we can add/remove this exact filter without
    /// trampling any user `af` chain. The filter is attached and detached
    /// rather than tweaked so disabling it has zero CPU cost.
    public func setDialogEnhanceEnabled(_ enabled: Bool) {
        guard client.isAlive else { return }
        if enabled {
            // `dynaudnorm` is a built-in libavfilter filter shipped with our
            // FFmpeg build. The parameters favour dialog: a longer window
            // (g=31), moderate target peak (p=0.9), and gentle max gain (m=4)
            // so explosions don't pump.
            client.command(["af", "add", "@plozz-dialog:lavfi=[dynaudnorm=g=31:m=4:p=0.9]"])
        } else {
            client.command(["af", "remove", "@plozz-dialog"])
        }
    }

    // MARK: - View

    public func makeVideoOutputView() -> UIView {
        if let outputView {
            plozzTrace("MPV.makeVideoOutputView: returning CACHED view")
            return outputView
        }
        plozzTrace("MPV.makeVideoOutputView: creating NEW MPVRenderView")
        let view = MPVRenderView(metalLayer: metalLayer)
        view.onWindowChange = { [weak self] window in
            guard let self else { return }
            // Once we're in a window, apply any pending HDR switch (covers the
            // case where load() ran before the view was in a hierarchy).
            if window != nil {
                self.applyDisplayCriteriaIfPossible()
            } else {
                // The view is leaving its window. If a switch is currently
                // applied, clear it now while the manager is still reachable so
                // the TV isn't stranded in a forced mode after dismissal.
                self.clearDisplayCriteria()
            }
        }
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
