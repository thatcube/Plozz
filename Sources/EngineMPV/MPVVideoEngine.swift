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

    /// Mirrors mpv's `eof-reached`: `true` once the stream hits a clean end and
    /// playback is no longer advancing. Used to release the wake lock at the end
    /// of a file even though `isPaused` may still read `false`.
    private var hasReachedEnd: Bool = false
    private var didAttachExternalAudio = false

    /// Keep the display awake only while mpv is actually advancing frames: not
    /// paused and not sitting at end-of-stream. Matches the native engine's
    /// `timeControlStatus == .playing` policy so the screensaver behaviour is
    /// identical regardless of which decoder is active.
    public var preventsDisplaySleep: Bool {
        !isPaused && !hasReachedEnd
    }
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var furthestObservedPosition: TimeInterval = 0

    public var audioTracks: [MediaTrack] { request?.audioTracks ?? [] }
    public var subtitleTracks: [MediaTrack] { request?.subtitleTracks ?? [] }

    // MARK: Orchestration callbacks

    public var onProgress: (@MainActor () -> Void)?
    public var onFailure: (@MainActor (AppError) -> Void)?
    public var onEnded: (@MainActor () -> Void)?

    // MARK: Configuration

    /// Data-driven decode/render/cache tuning. Defaults mirror the previous
    /// hardcoded behaviour plus smoother direct-play caching; a field flip (or a
    /// future settings toggle) re-tunes playback without touching `load()`.
    private let tuning: MPVPlaybackTuning

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
    /// Whether the pending/applied criteria carries the `'dvh1'` Dolby Vision
    /// codec tag (i.e. we're asking tvOS for a true DoVi HDMI signal). Cleared
    /// on the HDR10 fallback path.
    private var requestedDolbyVisionSwitch = false
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

    public init(tuning: MPVPlaybackTuning = .default, extraOptions: [String: String] = [:]) {
        self.tuning = tuning
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
        status = .loading
        teardownClient()

        self.request = request
        hasFailed = false
        isPaused = false
        hasReachedEnd = false
        didAttachExternalAudio = false
        currentTime = 0
        duration = 0
        lastReportedSecond = -1
        furthestObservedPosition = max(furthestObservedPosition, startPosition)

        guard client.create() else {
            fail(.unknown("mpv: failed to create player context"))
            return
        }

        client.requestLogMessages("no")
        let hdrMode = MPVHDR.mode(from: request.sourceMetadata?.video)

        // Hand mpv the metal layer as its render surface (must precede init).
        let layerPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        client.setWindowID(layerPointer)

        // Render + decode configuration (mirrors MPVKit's reference tvOS player),
        // driven by `tuning` so the decode path / renderer are a value flip. SDR
        // uses the lighter `gpu` vo; HDR/Dolby Vision keeps libplacebo `gpu-next`
        // (the only renderer that can reshape the DV RPU), so HDR is unchanged.
        client.setOptionString("vo", tuning.videoOutput(isHDR: hdrMode.isHDR))
        client.setOptionString("gpu-api", "vulkan")
        client.setOptionString("gpu-context", "moltenvk")
        client.setOptionString("hwdec", tuning.hwdec)
        client.setOptionString("video-rotate", "no")

        // Apply mpv video-sync / interpolation tuning (data-driven; defaults to
        // mpv's behaviour so SDR frame-rate matching below is what fixes cadence,
        // and these stay available to A/B on-device via `MPVPlaybackTuning`).
        if let videoSync = tuning.videoSync {
            client.setOptionString("video-sync", videoSync)
        }
        if tuning.interpolation {
            client.setOptionString("interpolation", "yes")
        }

        // Cache / demuxer tuning for smoother network direct play.
        for (key, value) in tuning.cacheOptionPairs() {
            client.setOptionString(key, value)
        }

        // Pick surface colorimetry from source metadata.
        metalLayer.configure(for: hdrMode)
        client.setOptionString("target-colorspace-hint", "yes")
        if let trc = MPVHDR.mpvTargetTRC(for: hdrMode) {
            client.setOptionString("target-trc", trc)
            client.setOptionString("target-prim", "bt.2020")
        }
        // Prepare (but don't yet apply) the tvOS display-mode switch; it needs a
        // live UIWindow and is applied after init / once the view is in a window.
        //
        // For Dolby Vision we build the criteria with the 'dvh1' codec FourCC so
        // tvOS negotiates a true DoVi HDMI signal (and the TV lights its "Dolby
        // Vision" banner) instead of plain HDR10. libplacebo still reshapes the
        // P5/P8 RPU to PQ HDR10 on the render surface — only the display-criteria
        // codec tag changes. If the 'dvh1' description can't be built for any
        // reason, fall back to the HDR10 ('hvc1'+PQ) switch rather than failing,
        // so we never drop to SDR for a DoVi source.
        //
        // For SDR we still build a criteria — but a *refresh-rate-only* one with
        // BT.709 colorimetry — so the panel frame-rate-matches the source (like
        // AVPlayer does) without ever switching into HDR. It degrades to no switch
        // when the source frame rate is unknown.
        let frameRate = Float(request.sourceMetadata?.video?.frameRate ?? 0)
        if let desc = MPVHDR.formatDescription(for: hdrMode, video: request.sourceMetadata?.video) {
            pendingDisplayCriteria = AVDisplayCriteria(refreshRate: frameRate, formatDescription: desc)
            requestedDolbyVisionSwitch = (hdrMode == .dolbyVision)
        } else if hdrMode == .dolbyVision,
                  let fallback = MPVHDR.hdr10FallbackFormatDescription(video: request.sourceMetadata?.video) {
            log.error("HDR: dvh1 Dolby Vision criteria unavailable; falling back to HDR10 (hvc1+PQ) display switch")
            pendingDisplayCriteria = AVDisplayCriteria(refreshRate: frameRate, formatDescription: fallback)
            requestedDolbyVisionSwitch = false
        } else if hdrMode == .sdr,
                  let sdrRefreshRate = FrameRateMatching.refreshRate(
                      forSourceFrameRate: request.sourceMetadata?.video?.frameRate),
                  let sdrDesc = MPVHDR.sdrFormatDescription(video: request.sourceMetadata?.video) {
            // SDR refresh-rate (frame-rate) match: drive the panel to a mode that
            // matches the source frame rate (e.g. 23.976fps → a 24Hz-family mode)
            // so mpv presents one source frame per refresh instead of cadencing
            // 23.98→60 — the late-frame cause AVPlayer avoids by matching natively.
            // BT.709 SDR criteria, so this never pushes the panel into HDR. tvOS
            // ignores it when the user's "Match Frame Rate" setting is off, and the
            // helper returns nil for unknown/implausible rates, so it's a silent
            // no-op that degrades gracefully and never makes SDR playback worse.
            pendingDisplayCriteria = AVDisplayCriteria(refreshRate: sdrRefreshRate, formatDescription: sdrDesc)
            requestedDolbyVisionSwitch = false
        } else {
            pendingDisplayCriteria = nil
            requestedDolbyVisionSwitch = false
        }

        // Match-OS-language subtitle/audio defaults, harmless when tracks are
        // explicitly selected later by the view model.
        client.setOptionString("subs-match-os-language", "yes")
        client.setOptionString("subs-fallback", "yes")
        for (key, value) in extraOptions {
            client.setOptionString(key, value)
        }

        // Adaptive sources (e.g. a high-resolution YouTube DASH trailer) deliver
        // video and audio as two separate URLs. AVPlayer can't combine bare URLs,
        // but mpv can. NOTE: the companion audio can NOT be attached here: mpv's
        // `--audio-file` is a CLI/config-file-only alias that the libmpv API
        // silently ignores, and the real `--audio-files` option splits its value
        // on `:` — which every `https://` URL contains — so it mangles the URL.
        // Instead we attach the audio with the `audio-add` command once the video
        // file has loaded (see `attachExternalAudioIfNeeded`), where the URL is
        // passed as a single atomic argv entry with no separator parsing.

        guard await waitForRenderableSurface() else {
            teardownClient()
            fail(.unknown("mpv: render surface was not ready in time"))
            return
        }


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

        // Apply the HDR display switch now (the view is usually already in a
        // window during playback); otherwise it lands via `onWindowChange`.
        applyDisplayCriteriaIfPossible()
        updateHDRStatus(mode: hdrMode)

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
        // Release any HDR display-mode switch so the TV isn't left stuck in a
        // forced mode after playback stops.
        clearDisplayCriteria()
        pendingDisplayCriteria = nil
        requestedDolbyVisionSwitch = false
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
        log.info("HDR: requested display-mode switch (dolbyVision=\(self.requestedDolbyVisionSwitch, privacy: .public) matchingEnabled=\(manager.isDisplayCriteriaMatchingEnabled, privacy: .public))")
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
            dolbyVisionRequested: requestedDolbyVisionSwitch && didApplyDisplayCriteria,
            displayMatchingEnabled: matchingEnabled)
        log.info("HDR status mode=\(mode.rawValue, privacy: .public) surface=\(info.pixelFormat, privacy: .public) colorspace=\(info.colorspace ?? "nil", privacy: .public) switchRequested=\(self.didApplyDisplayCriteria, privacy: .public) dolbyVision=\(self.requestedDolbyVisionSwitch && self.didApplyDisplayCriteria, privacy: .public) matchingEnabled=\(matchingEnabled, privacy: .public)")
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

    /// Toggles a labelled `dialoguenhance` audio filter — FFmpeg's purpose-built
    /// dialogue enhancer that lifts the centre/voice channel out of a stereo or
    /// surround mix so speech stays intelligible without raising music/effects.
    /// We use the `@plozz-dialog` label so we can add/remove this exact filter
    /// without trampling any user `af` chain, and it is attached/detached rather
    /// than tweaked so disabling it has zero CPU cost. If the FFmpeg build
    /// lacks `dialoguenhance`, mpv simply logs and no-ops (graceful degrade).
    public func setDialogEnhanceEnabled(_ enabled: Bool) {
        guard client.isAlive else { return }
        if enabled {
            // `dialoguenhance` operates on a stereo downmix and boosts the
            // phase-correlated centre content (dialogue). original=1 keeps the
            // base mix, enhance=1 adds a full-strength enhanced centre, voice=2
            // widens the band treated as voice so more speech is captured.
            client.command(["af", "add", "@plozz-dialog:lavfi=[dialoguenhance=original=1:enhance=1:voice=2]"])
        } else {
            client.command(["af", "remove", "@plozz-dialog"])
        }
    }

    // MARK: - View

    public func makeVideoOutputView() -> UIView {
        if let outputView {
            return outputView
        }
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
            attachExternalAudioIfNeeded()
        case .propertyChanged(let name, let value):
            handleProperty(name, value: value)
        case .endFile(let isError, let isEOF):
            if isError {
                fail(.invalidResponse)
            } else if isEOF {
                hasReachedEnd = true
                onEnded?()
            }
        case .shutdown:
            status = .idle
        }
    }

    /// Attaches the companion audio track for adaptive (separate video+audio)
    /// sources once the video file is loaded. Uses the `audio-add` command — the
    /// URL is passed as a single atomic argv entry, so it survives unparsed
    /// (unlike the `--audio-file`/`--audio-files` options, which the libmpv API
    /// ignores or mangles on `:`). `select` makes mpv play it, giving the
    /// otherwise-silent video-only DASH stream its sound back, kept in sync with
    /// the video timeline.
    private func attachExternalAudioIfNeeded() {
        guard !didAttachExternalAudio, let audioURL = request?.externalAudioURL else { return }
        didAttachExternalAudio = true
        _ = client.command(["audio-add", audioURL.absoluteString, "select"])
    }

    /// Applies an observed property change. The new value rides along in `value`
    /// (read off the mpv event at parse time), so the hot per-frame `time-pos`
    /// path no longer calls `mpv_get_property` on the main actor — which would
    /// re-acquire the mpv core lock and stall behind a busy render thread,
    /// producing main-thread hitches during heavy playback. Falls back to a
    /// synchronous get only if mpv didn't attach a value.
    private func handleProperty(_ name: String, value: MPVPropertyValue) {
        switch name {
        case MPVProperty.timePos:
            let seconds = value.doubleValue ?? client.getDouble(MPVProperty.timePos)
            guard seconds.isFinite else { return }
            currentTime = max(0, seconds)
            furthestObservedPosition = max(furthestObservedPosition, currentTime)
            reportProgressIfNeeded(at: currentTime)
        case MPVProperty.duration:
            let durationValue = value.doubleValue ?? client.getDouble(MPVProperty.duration)
            if durationValue.isFinite { duration = max(0, durationValue) }
        case MPVProperty.pause:
            isPaused = value.flagValue ?? client.getFlag(MPVProperty.pause)
        case MPVProperty.eofReached:
            // `eof-reached` flips true at a clean end-of-stream; treated as a
            // benign stop (the owner reads `currentTime`/`duration`), not a fail.
            // Tracked so the display wake lock is released at end-of-file even
            // while `pause` still reads false.
            hasReachedEnd = value.flagValue ?? client.getFlag(MPVProperty.eofReached)
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
    ///
    /// All events drained in one pass are marshalled to the main actor in a
    /// **single** hop (preserving FIFO order), rather than one `DispatchQueue.main`
    /// dispatch per event. libmpv fires a wakeup per `time-pos` change — i.e. once
    /// per displayed frame — so coalescing cuts the steady main-thread scheduling
    /// churn during playback (fewer dispatches/sec for the same work).
    nonisolated fileprivate func scheduleEventDrain() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            var batch: [MPVEvent] = []
            self.client.drainEvents { batch.append($0) }
            guard !batch.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for event in batch { self.apply(event) }
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
    /// Active hardware decoder name, or `no`/empty when decoding on the CPU.
    static let hwdecCurrent = "hwdec-current"
    /// Frames the decoder dropped because it couldn't keep up (decode bottleneck).
    static let decoderFrameDropCount = "decoder-frame-drop-count"
    /// Frames dropped at the output stage (render / display-timing bottleneck).
    static let frameDropCount = "frame-drop-count"
    /// Frame rate actually being rendered right now.
    static let estimatedVFFPS = "estimated-vf-fps"
    /// The container's declared frame rate (the target to keep up with).
    static let containerFPS = "container-fps"
}

// MARK: - Live engine stats (diagnostics overlay)

extension MPVVideoEngine: PlaybackStatsProviding {
    /// Reads libmpv's own runtime-health properties so the diagnostics overlay can
    /// answer "is the device keeping up?" for the mpv engine — which has no
    /// `AVPlayer` for the platform sampler to read. All reads are cheap synchronous
    /// property gets funnelled through the thread-safe ``MPVClient``; called ~1s.
    public func sampleEngineStats() -> PlaybackEngineStats? {
        guard client.isAlive else { return nil }
        let hwdec = client.getString(MPVProperty.hwdecCurrent)
        return PlaybackEngineStats(
            decodePath: PlaybackEngineStats.decodePath(fromHWDecCurrent: hwdec),
            hwdecName: hwdec,
            decoderDroppedFrames: client.getInt(MPVProperty.decoderFrameDropCount).map(Int.init),
            lateFrames: client.getInt(MPVProperty.frameDropCount).map(Int.init),
            renderedFrameRate: nonNegative(client.getDouble(MPVProperty.estimatedVFFPS)),
            containerFrameRate: nonNegative(client.getDouble(MPVProperty.containerFPS))
        )
    }

    /// `getDouble` returns `0` for an unavailable property; treat that as "no
    /// reading" so the overlay hides the row rather than showing a bogus `0 fps`.
    private func nonNegative(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }
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
