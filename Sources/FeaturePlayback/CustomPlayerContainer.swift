#if canImport(UIKit)
import UIKit
import SwiftUI
import CoreModels
import CoreNetworking

/// Callbacks the input controller invokes on the owning view model. Kept as a
/// plain value of closures so the UIKit layer never imports the view model.
@MainActor
struct PlayerActions {
    /// Request a *committed* seek to `target`. The view model coalesces rapid
    /// calls into a single in-flight seek that always targets the latest
    /// requested time, so rapid left/right skips can NEVER race or snap back.
    var seek: (TimeInterval) -> Void = { _ in }
    var togglePlayPause: () -> Void = {}
    var selectAudio: (Int) -> Void = { _ in }
    var selectSubtitle: (Int) -> Void = { _ in }
    var setPlaybackSpeed: (Double) -> Void = { _ in }
    var setAudioDelay: (TimeInterval) -> Void = { _ in }
    var setSubtitleDelay: (TimeInterval) -> Void = { _ in }
    var setDialogEnhance: (Bool) -> Void = { _ in }
    var selectLocalRemuxStrategy: (String) -> Void = { _ in }
    var reloadLocalRemuxPlayback: () -> Void = {}
    var runRemuxSeekTortureTest: () -> Void = {}
    /// Seek past the active intro/credits segment (Skip button Select).
    var skipSegment: () -> Void = {}
    /// Auto-seek past the active segment (no button) when Auto-skip is enabled.
    var autoSkipSegment: () -> Void = {}
    /// Dismiss the skip button without seeking (Menu / swipe away).
    var dismissSkip: () -> Void = {}
    var dismiss: () -> Void = {}
}

/// The shared, **engine-agnostic** custom player UI: it hosts whatever bare video
/// surface the active `VideoEngine` vends (`makeVideoOutputView()`), layers a
/// SwiftUI controls overlay on top, and handles all Siri Remote input in UIKit
/// (the only reliable way to get analog touch-surface scrubbing on tvOS). It
/// drives playback purely through the `VideoEngine` protocol and the
/// `PlayerActions` closures, so any engine (AVPlayer today, libmpv/VLCKit later)
/// reuses it without change.
struct CustomPlayerContainer: UIViewControllerRepresentable {
    let engine: any VideoEngine
    let model: PlayerControlsModel
    let actions: PlayerActions
    let scrubPreview: ScrubPreviewSource?
    let themePalette: ThemePaletteBox

    func makeUIViewController(context: Context) -> PlayerInputViewController {
        let controller = PlayerInputViewController(engine: engine, model: model, actions: actions)
        controller.configureScrubPreview(scrubPreview)
        controller.attachVideoSurface()
        controller.attachControls(themePalette: themePalette)
        return controller
    }

    func updateUIViewController(_ controller: PlayerInputViewController, context: Context) {
        controller.actions = actions
    }
}

/// Minimal, controls-free host for an engine's bare video surface. Used during
/// loading so engines that require an attached/windowed render target (mpv)
/// can initialize before playback reaches `.ready`.
struct VideoSurfaceContainer: UIViewRepresentable {
    let engine: any VideoEngine

    func makeUIView(context: Context) -> UIView {
        let root = UIView(frame: .zero)
        root.backgroundColor = .black
        attachSurface(to: root)
        return root
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attachSurface(to: uiView)
    }

    private func attachSurface(to root: UIView) {
        let surface = engine.makeVideoOutputView()
        guard surface.superview !== root else { return }
        surface.removeFromSuperview()
        surface.frame = root.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.isUserInteractionEnabled = false
        root.insertSubview(surface, at: 0)
    }
}

/// A lightweight box so the SwiftUI `ThemePalette` (a CoreUI type) can cross the
/// representable boundary without FeaturePlayback's UIKit layer depending on it
/// structurally; the overlay uses it directly.
struct ThemePaletteBox {
    let makeControls: (PlayerControlsModel, PlayerOptionsActions, @escaping () -> Void) -> AnyView
    /// Builds the focusable Skip Intro/Credits button. `onSkip` seeks past the
    /// active segment; `onDismiss` hides it without seeking. Both also return
    /// focus to the scrub surface (the controller owns that transition).
    let makeSkipButton: (PlayerControlsModel, @escaping () -> Void, @escaping () -> Void) -> AnyView
}

/// The focusable root view that receives Siri Remote presses and indirect-touch
/// pans. The engine's video surface and the controls overlay are added as
/// non-interactive subviews, so focus stays here while scrubbing. While the
/// bottom control bar owns focus, `allowsFocus` is flipped off so the focus
/// engine can't bounce back here (Up exits via the control bar instead).
final class PlayerInputView: UIView {
    var allowsFocus = true
    override var canBecomeFocused: Bool { allowsFocus }
}

/// Owns the focusable input surface, hosts the engine's bare video output view,
/// the SwiftUI controls overlay, and every Siri Remote gesture. Scrubbing is
/// preview-only — the engine is never seeked until the viewer commits (Select),
/// so the scrub stays perfectly smooth regardless of stream/seek latency. All
/// playback is driven through the `VideoEngine` protocol + `PlayerActions`, never
/// a concrete player, so this UI is reused verbatim by every engine.
final class PlayerInputViewController: UIViewController {
    var actions: PlayerActions
    private let engine: any VideoEngine
    private let model: PlayerControlsModel
    private var thumbnailLoader: (any ScrubThumbnailProviding)?

    private var autoHideTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var skipHintTask: Task<Void, Never>?
    /// The pan-gesture `translation.x` from the *previous* scrub sample. Each
    /// pan event scrubs by the *increment* since this value (not the cumulative
    /// translation against a base), which is what lets the velocity-accelerated
    /// transfer function apply per-sample gain. Seeded with the translation at
    /// the axis decision so the dead-zone travel spent deciding the axis never
    /// counts as scrub distance, and never mutated on the recognizer itself
    /// (no `setTranslation(.zero)`), so the head can't snap backward between
    /// events.
    private var scrubLastTranslationX: CGFloat = 0
    /// Low-pass-filtered pan speed (points/sec) used to drive the acceleration
    /// gain. The recognizer's raw `velocity` spikes sample-to-sample, and feeding
    /// that straight into the gain made fast flicks feel *jumpy* (the multiplier
    /// lurched between events). An exponential moving average smooths it so the
    /// gain ramps fluidly. Reset to 0 at the start of each scrub.
    private var scrubSmoothedSpeed: Double = 0
    private var resumeAfterScrub = false

    /// Suppresses the tvOS screensaver / Apple TV sleep while video is actively
    /// playing, and releases it the instant playback pauses, ends, or this host
    /// goes away. Driven every refresh tick off `engine.preventsDisplaySleep`, so
    /// it behaves identically for every engine/decoder (AVPlayer *and* mpv).
    private let idleSleepGuard = IdleSleepGuard()

    /// Whether the Siri Remote currently drives the scrub surface or the bottom
    /// control bar. In `.controlBar` the surface gesture recognizers are disabled
    /// so the SwiftUI focus engine owns navigation.
    private enum FocusContext { case surface, controlBar, skipButton }
    private var focusContext: FocusContext = .surface

    /// The always-attached, focusable bottom control bar. It only takes focus
    /// while `focusContext == .controlBar`.
    private var controlBarHost: UIHostingController<AnyView>?

    /// The always-attached Skip Intro/Credits button overlay. Interactive (and
    /// focused) only while `focusContext == .skipButton`; collapses to nothing
    /// when no segment is active. Tracked so presentation only flips on change.
    private var skipButtonHost: UIHostingController<AnyView>?
    private var presentingSkipButton = false
    /// In `.autoDelay`, the playback position (seconds) at which the presented
    /// Skip button auto-skips. Tied to playback position (not wall-clock) so the
    /// countdown pauses with the video. `nil` outside an active delay.
    private var autoSkipAtSeconds: TimeInterval?

    /// Surface gesture recognizers we toggle off while the control bar owns focus.
    private var surfaceRecognizers: [UIGestureRecognizer] = []

    private var playerInputView: PlayerInputView? { view as? PlayerInputView }

    init(engine: any VideoEngine, model: PlayerControlsModel, actions: PlayerActions) {
        self.engine = engine
        self.model = model
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let inputView = PlayerInputView()
        inputView.backgroundColor = .black
        view = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installGestures()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Make sure our input surface owns the focus so the Siri Remote's presses
        // and indirect-touch pans reach our gesture recognizers.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        startRefreshLoop()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
        // Leaving playback: let the screensaver / Apple TV sleep resume.
        idleSleepGuard.allowSleep()
    }

    override var canBecomeFirstResponder: Bool { true }

    func configureScrubPreview(_ source: ScrubPreviewSource?) {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailLoader = nil
        model.previewImage = nil

        guard let source else {
            PlozzLog.playback.debug("Scrub preview unavailable: provider did not supply a source")
            return
        }
        guard source.isUsable else {
            PlozzLog.playback.debug("Scrub preview unavailable: source exists but is not usable")
            return
        }
        switch source {
        case .tiled(let manifest):
            thumbnailLoader = TrickplayThumbnailLoader(manifest: manifest)
            PlozzLog.playback.debug("Configured Jellyfin tiled scrub preview (\(manifest.tileURLs.count) tiles, intervalMs=\(manifest.intervalMs))")
        case .plexBIF(let url):
            thumbnailLoader = PlexBIFThumbnailLoader(url: url)
            PlozzLog.playback.debug("Configured Plex BIF scrub preview url=\(PlozzLog.redact(url: url))")
        }
    }

    /// Hosts the engine's bare video surface as the backmost, non-interactive
    /// layer. The engine keeps it fed across reloads, so we add it once.
    func attachVideoSurface() {
        let surface = engine.makeVideoOutputView()
        surface.frame = view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.isUserInteractionEnabled = false
        view.insertSubview(surface, at: 0)
    }

    /// Hosts the combined transport + focusable control bar. It stays attached
    /// for the player's lifetime; the scrubber/title render whenever the controls
    /// are visible, while focus only drops into the button row (and the host
    /// becomes interactive) when `focusContext == .controlBar`. Otherwise its
    /// interaction is off so indirect-touch scrub pans flow to the surface and it
    /// can't steal focus.
    func attachControls(themePalette: ThemePaletteBox) {
        let exitToSurface: () -> Void = { [weak self] in self?.exitToSurface() }
        let actions = PlayerOptionsActions(
            selectAudio: { [weak self] in self?.actions.selectAudio($0) },
            selectSubtitle: { [weak self] in self?.actions.selectSubtitle($0) },
            setPlaybackSpeed: { [weak self] in self?.actions.setPlaybackSpeed($0) },
            setAudioDelay: { [weak self] in self?.actions.setAudioDelay($0) },
            setSubtitleDelay: { [weak self] in self?.actions.setSubtitleDelay($0) },
            setDialogEnhance: { [weak self] in self?.actions.setDialogEnhance($0) },
            selectLocalRemuxStrategy: { [weak self] in self?.actions.selectLocalRemuxStrategy($0) },
            reloadLocalRemuxPlayback: { [weak self] in self?.actions.reloadLocalRemuxPlayback() },
            runRemuxSeekTortureTest: { [weak self] in self?.actions.runRemuxSeekTortureTest() }
        )
        let host = UIHostingController(rootView: themePalette.makeControls(model, actions, exitToSurface))
        host.view.backgroundColor = .clear
        // Off until the viewer drops focus into the bar (swipe-down / Down).
        host.view.isUserInteractionEnabled = false
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        controlBarHost = host

        // Skip Intro/Credits overlay on top of the control bar. Off until a
        // segment becomes active and the viewer is on the scrub surface.
        let skipHost = UIHostingController(
            rootView: themePalette.makeSkipButton(
                model,
                { [weak self] in self?.performSkip() },
                { [weak self] in self?.dismissSkipButton() }
            )
        )
        skipHost.view.backgroundColor = .clear
        skipHost.view.isUserInteractionEnabled = false
        addChild(skipHost)
        skipHost.view.frame = view.bounds
        skipHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(skipHost.view)
        skipHost.didMove(toParent: self)
        skipButtonHost = skipHost
    }

    // MARK: Engine state refresh

    /// Polls the engine on a light cadence and mirrors its live state into the
    /// observable `controls` model the overlay reads. Engine-agnostic: it only
    /// touches the `VideoEngine` protocol, so it works for any engine.
    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshFromEngine()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func refreshFromEngine() {
        // Keep the display awake only while frames are actually advancing.
        // Evaluated every tick, before any early-return, so a pause, end-of-
        // stream, or stall promptly releases the wake lock for every engine.
        idleSleepGuard.keepAwake(engine.preventsDisplaySleep)
        let duration = engine.duration
        if duration > 0 { model.duration = duration }
        // Don't fight the scrub head or an in-flight committed seek.
        if model.isScrubbing { return }
        let engineTime = engine.currentTime
        if let pending = model.pendingSeekTarget {
            // A committed seek is in flight (or just finished). Holding the bar
            // at the optimistic target until the engine actually arrives is the
            // entire fix for the "press right → snap back" feel: a poll arriving
            // between the optimistic update and the engine catching up would
            // otherwise overwrite `currentSeconds` with the stale pre-seek time.
            // Once the engine's position is within tolerance, release.
            if abs(engineTime - pending) < 0.75 {
                model.pendingSeekTarget = nil
                model.currentSeconds = engineTime
            }
            // else: keep `currentSeconds` pinned to the optimistic value.
        } else {
            model.currentSeconds = engineTime
        }
        model.bufferedSeconds = engine.bufferedPosition
        model.isPaused = engine.isPaused
        evaluateSkipPresentation()
    }

    // MARK: Skip intro/credits presentation

    /// Presents, auto-skips, or hides the Skip affordance as the live position
    /// enters / leaves a skippable segment, per the active `skipMode`:
    ///  * `.on` — present the focusable button (manual skip).
    ///  * `.autoDelay` — present the button, then skip once playback advances
    ///    `autoSkipDelay` seconds (the button's ring counts the wait down; the
    ///    viewer can skip now or swipe-up to cancel).
    ///  * `.autoInstant` — skip immediately with only a brief notice, no button.
    ///  * `.off` — never reached (markers aren't fetched).
    /// Only auto-presents from the scrub surface so it never yanks focus out of
    /// the control bar or a scrub; returns focus to the surface once the segment
    /// passes or is dismissed.
    private func evaluateSkipPresentation() {
        guard model.activeSkipSegment != nil else {
            if presentingSkipButton { exitSkipButton() }
            return
        }

        switch model.skipMode {
        case .off, .on:
            guard !presentingSkipButton, focusContext == .surface, !model.isScrubbing else { return }
            enterSkipButton()

        case .autoInstant:
            guard !model.isScrubbing else { return }
            actions.autoSkipSegment()

        case .autoDelay:
            if presentingSkipButton {
                // Fire once playback reaches the deadline (skips while paused are
                // deferred until it resumes, by design — the countdown is tied to
                // playback position, not wall-clock).
                if let deadline = autoSkipAtSeconds, model.currentSeconds >= deadline, !model.isScrubbing {
                    autoSkipFromDelay()
                }
                return
            }
            guard focusContext == .surface, !model.isScrubbing else { return }
            autoSkipAtSeconds = model.currentSeconds + SkipIntrosMode.autoSkipDelay
            model.autoSkipAtSeconds = autoSkipAtSeconds
            enterSkipButton()
        }
    }

    private func enterSkipButton() {
        presentingSkipButton = true
        focusContext = .skipButton
        // Clear the transport so the skip button floats on its own — it must stay
        // visible even when the scrub bar / controls are hidden, not ride on top
        // of them. (Auto-hide otherwise can't fire here: it only hides while the
        // surface owns focus, and the skip button has taken focus.)
        hideControls()
        setSurfaceRecognizers(enabled: false)
        skipButtonHost?.view.isUserInteractionEnabled = true
        playerInputView?.allowsFocus = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Returns focus to the scrub surface after the skip button is used,
    /// dismissed, or its segment window passes.
    private func exitSkipButton() {
        presentingSkipButton = false
        autoSkipAtSeconds = nil
        model.autoSkipAtSeconds = nil
        skipButtonHost?.view.isUserInteractionEnabled = false
        // The control bar may have taken over in the meantime; only restore the
        // surface if the skip button was the focus owner.
        if focusContext == .skipButton {
            focusContext = .surface
            playerInputView?.allowsFocus = true
            setSurfaceRecognizers(enabled: true)
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// Skip button Select: seek past the active segment, then return to surface.
    private func performSkip() {
        actions.skipSegment()
        exitSkipButton()
        flashControls()
    }

    /// `.autoDelay` deadline reached: seek past the segment (no notice — the
    /// button was already visible) and return to the surface.
    private func autoSkipFromDelay() {
        actions.skipSegment()
        exitSkipButton()
    }

    /// Skip button Menu / swipe-up: hide without seeking, return to surface.
    private func dismissSkipButton() {
        actions.dismissSkip()
        exitSkipButton()
    }

    // MARK: Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // While the bottom control bar is active, hand focus to it so the Siri
        // Remote drives its native buttons; the skip button likewise grabs focus
        // while it's presented; otherwise the input surface owns focus so
        // pans/presses reach our gesture recognizers.
        if focusContext == .skipButton, let skipButtonHost {
            return [skipButtonHost.view]
        }
        if focusContext == .controlBar, let controlBarHost {
            return [controlBarHost.view]
        }
        return [view]
    }

    // MARK: Gestures

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)
        surfaceRecognizers.append(pan)

        surfaceRecognizers.append(addPress(.select, #selector(handleSelect)))
        surfaceRecognizers.append(addPress(.playPause, #selector(handlePlayPause)))
        surfaceRecognizers.append(addPress(.menu, #selector(handleMenu)))
        surfaceRecognizers.append(addPress(.leftArrow, #selector(handleLeft)))
        surfaceRecognizers.append(addPress(.rightArrow, #selector(handleRight)))
        surfaceRecognizers.append(addPress(.upArrow, #selector(handleUp)))
        surfaceRecognizers.append(addPress(.downArrow, #selector(handleDown)))
    }

    @discardableResult
    private func addPress(_ type: UIPress.PressType, _ action: Selector) -> UIGestureRecognizer {
        let recognizer = UITapGestureRecognizer(target: self, action: action)
        recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(recognizer)
        return recognizer
    }

    // MARK: Scrubbing

    /// Axis decision for the current pan. Decided once on the first sample that
    /// crosses the dead zone; locked for the rest of the gesture so a small
    /// vertical drift inside a horizontal scrub never bleeds into the bar (and
    /// — more importantly — a vertical swipe NEVER moves the scrub head).
    private enum PanAxis { case undecided, horizontal, verticalIgnored }
    private var panAxis: PanAxis = .undecided
    /// Distance (points) a touch must travel before we lock to an axis. Smaller
    /// than the swipe-down recognizer's threshold so deliberate horizontal
    /// scrubs feel immediate but a stray vertical drift can still ignore.
    private let panAxisDeadZone: CGFloat = 18

    /// EMA weight for the per-sample pan-speed used to drive scrub acceleration.
    /// Lower = smoother (more lag), higher = more responsive (more jitter). 0.25
    /// removes the sample-to-sample velocity spikes that made flicks feel jumpy
    /// while still tracking a real flick within a few events.
    private let scrubSpeedSmoothing: Double = 0.25

    private var scrubTuning: ScrubGeometry.Tuning {
        // Base seconds-per-point scales with runtime so the *fraction* of the
        // content a swipe covers stays roughly consistent. The reference is a 2h
        // film (scale 1.0 → ~0.18 s/pt, the silky fine-scrub feel). The floor is
        // low (0.3) so short TV episodes scale right down — otherwise the same
        // s/pt crosses a much bigger fraction of a 25-min episode and feels way
        // too fast. A fast flick accelerates up to maxAccelMultiplier via a
        // smoothstep curve (see ScrubGeometry); the ceiling is modest so flicks
        // stay controllable.
        let durationScale = min(max(model.duration / 7200, 0.3), 1.6)
        return ScrubGeometry.Tuning(
            baseSecondsPerPoint: 0.18 * durationScale,
            accelOnsetSpeed: 500,
            accelSaturationSpeed: 3500,
            maxAccelMultiplier: 5)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard model.duration > 0 else { return }
        guard focusContext == .surface else { return }
        switch gesture.state {
        case .began:
            panAxis = .undecided
            scrubLastTranslationX = 0
        case .changed:
            let translation = gesture.translation(in: view)
            if panAxis == .undecided {
                // Wait for a clear directional signal before committing. While
                // undecided, NOTHING happens — the scrub head doesn't move and
                // we don't begin a scrub, so vertical swipes that the system
                // turns into a swipe-down recognizer don't briefly nudge the
                // bar before being suppressed.
                let absX = abs(translation.x)
                let absY = abs(translation.y)
                guard max(absX, absY) >= panAxisDeadZone else { return }
                if absX >= absY {
                    panAxis = .horizontal
                    beginScrub()
                    // Seed the incremental anchor at *this* translation so the
                    // axis-decision dead-zone travel is excluded (the first
                    // scrub sample moves by zero, not the cumulative pan
                    // offset). We track our own previous-translation rather than
                    // calling `gesture.setTranslation(.zero)`, which would leave
                    // the pre-reset `translation` applied this event and a
                    // reset-to-tiny translation next event — stepping the bar
                    // backward by the gap.
                    scrubLastTranslationX = translation.x
                    scrubSmoothedSpeed = 0
                } else {
                    panAxis = .verticalIgnored
                    // A deliberate downward swipe reveals the controls and drops
                    // focus into the bottom button row — handled here off the pan
                    // (rather than a separate swipe recognizer, which competes
                    // with this pan and was unreliable).
                    if translation.y > 0 {
                        enterControlBar()
                    }
                    return
                }
            }
            guard panAxis == .horizontal else { return }
            // Scrub by the increment since the last sample, with gain that ramps
            // up with pan speed: slow drags stay precise, fast flicks fling far.
            // The raw recognizer velocity is jittery, so smooth it (EMA) before
            // it drives the gain — otherwise fast flicks feel jumpy.
            let dx = Double(translation.x - scrubLastTranslationX)
            scrubLastTranslationX = translation.x
            let rawSpeed = abs(Double(gesture.velocity(in: view).x))
            scrubSmoothedSpeed += (rawSpeed - scrubSmoothedSpeed) * scrubSpeedSmoothing
            model.scrubSeconds = ScrubGeometry.advance(
                scrubSeconds: model.scrubSeconds,
                translationDeltaPoints: dx,
                speedPointsPerSecond: scrubSmoothedSpeed,
                tuning: scrubTuning,
                duration: model.duration)
            updatePreviewThumbnail()
        case .ended, .cancelled, .failed:
            // Auto-commit a horizontal scrub on lift, like Apple's own
            // AVPlayerViewController: the user expects the bar's final position
            // to take effect without a separate Select press. A vertical-only
            // gesture never started a scrub, so nothing to commit.
            if panAxis == .horizontal, model.isScrubbing {
                commitScrub()
            }
            panAxis = .undecided
        default:
            break
        }
    }

    private func beginScrub() {
        cancelAutoHide()
        resumeAfterScrub = !model.isPaused
        model.isScrubbing = true
        model.scrubSeconds = model.currentSeconds
        model.controlsVisible = true
        // Pause the underlying stream while previewing; we resume on commit.
        if !model.isPaused { actions.togglePlayPause() }
        updatePreviewThumbnail()
    }

    private func commitScrub() {
        guard model.isScrubbing else { return }
        let target = model.scrubSeconds
        // Commit the optimistic target BEFORE leaving scrub mode. While
        // scrubbing, `displaySeconds` reads `scrubSeconds` (== target); once
        // `isScrubbing` clears it reads `currentSeconds`. Seeking first makes
        // `requestSeek` set `currentSeconds = target` up front, so the handoff is
        // scrubSeconds(target) → currentSeconds(target) with no one-frame dip
        // back to the stale pre-scrub position.
        actions.seek(target)
        model.isScrubbing = false
        model.previewImage = nil
        model.seekIndicatorOnLeft = false
        if resumeAfterScrub { actions.togglePlayPause() }
        scheduleAutoHide()
    }

    private func cancelScrub() {
        guard model.isScrubbing else { return }
        model.isScrubbing = false
        model.previewImage = nil
        if resumeAfterScrub { actions.togglePlayPause() }
        scheduleAutoHide()
    }

    private func updatePreviewThumbnail() {
        guard let loader = thumbnailLoader else {
            model.previewImage = nil
            return
        }
        let requestedSeconds = model.scrubSeconds
        // Instant swap when the tile is already cached (the common case while
        // dragging within one tile) keeps scrubbing fluid; otherwise fetch async.
        if let cached = loader.cachedThumbnail(forSeconds: requestedSeconds) {
            model.previewImage = cached
            return
        }
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            let requestedImage = await loader.thumbnail(forSeconds: requestedSeconds)
            guard let self, !Task.isCancelled, self.model.isScrubbing else { return }

            let currentSeconds = self.model.scrubSeconds
            // If the scrub head moved while this request was in flight, refresh for
            // the current position so we don't drop previews on fast pans.
            let image: CGImage?
            if abs(currentSeconds - requestedSeconds) < 0.001 {
                image = requestedImage
            } else if let cachedCurrent = loader.cachedThumbnail(forSeconds: currentSeconds) {
                image = cachedCurrent
            } else {
                image = await loader.thumbnail(forSeconds: currentSeconds)
            }

            guard !Task.isCancelled, self.model.isScrubbing else { return }
            self.model.previewImage = image
        }
    }

    // MARK: Button handlers

    @objc private func handleSelect() {
        guard focusContext == .surface else { return }
        if model.isScrubbing {
            commitScrub()
        } else {
            actions.togglePlayPause()
            flashControls()
        }
    }

    @objc private func handlePlayPause() {
        guard focusContext == .surface else { return }
        if model.isScrubbing { commitScrub() }
        actions.togglePlayPause()
        flashControls()
    }

    @objc private func handleMenu() {
        if model.isScrubbing {
            cancelScrub()
        } else if model.controlsVisible {
            hideControls()
        } else {
            actions.dismiss()
        }
    }

    @objc private func handleLeft() {
        guard focusContext == .surface else { return }
        skip(by: -model.skipBackwardInterval.seconds)
    }
    @objc private func handleRight() {
        guard focusContext == .surface else { return }
        skip(by: model.skipForwardInterval.seconds)
    }

    /// A Down press from the scrub surface reveals the controls and drops focus
    /// straight into the bottom control bar — the same destination as swipe-down.
    @objc private func handleDown() {
        guard focusContext == .surface, !model.isScrubbing else { return }
        enterControlBar()
    }

    /// An Up press from the scrub surface reveals the transport without moving
    /// focus off the surface, matching the swipe-up reveal.
    @objc private func handleUp() {
        guard focusContext == .surface, !model.isScrubbing else { return }
        flashControls()
    }

    private func skip(by seconds: TimeInterval) {
        guard model.duration > 0 else { return }
        if model.isScrubbing {
            model.scrubSeconds = min(max(0, model.scrubSeconds + seconds), model.duration)
            updatePreviewThumbnail()
        } else {
            // The crucial bit: stack on the LAST requested target, not on the
            // engine's possibly-stale `currentTime`. Without this, two fast
            // right presses both compute the same pre-seek position and
            // produce a single skip — exactly the "I pressed twice but
            // nothing extra happened" bug. The view model coalesces all of
            // them into one final seek.
            let base = model.pendingSeekTarget ?? model.currentSeconds
            let target = min(max(0, base + seconds), model.duration)
            actions.seek(target)
            flashControls()
            flashSkipHint(forward: seconds > 0)
        }
    }

    // MARK: Skip hint

    /// Pops the transient skip indicator and schedules its quick fade. Re-arming
    /// the timer + bumping the token on each press makes rapid skips re-pop
    /// rather than sit static, matching Apple's player feel.
    private func flashSkipHint(forward: Bool) {
        model.skipHintForward = forward
        model.seekIndicatorOnLeft = !forward
        model.skipHintToken &+= 1
        model.skipHintVisible = true
        skipHintTask?.cancel()
        skipHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard let self, !Task.isCancelled else { return }
            self.model.skipHintVisible = false
        }
    }

    // MARK: Controls visibility

    private func flashControls() {
        model.controlsVisible = true
        scheduleAutoHide()
    }

    private func hideControls() {
        cancelAutoHide()
        model.controlsVisible = false
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.model.isScrubbing && !self.model.isPaused && self.focusContext == .surface {
                self.model.controlsVisible = false
            }
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // MARK: Control bar focus

    /// Reveals the transport and drops Siri-Remote focus into the bottom control
    /// bar (Audio & Subtitles · Speed · A/V Sync). Surface scrub/skip recognizers
    /// are disabled so the SwiftUI focus engine owns navigation. Playback keeps
    /// running so track/speed/sync tweaks apply live (Infuse-style).
    private func enterControlBar() {
        guard focusContext == .surface else { return }
        guard hasControlBarContent else {
            // Nothing to configure for this engine/source — just flash the
            // transport instead of dropping focus into an empty bar.
            flashControls()
            return
        }
        cancelAutoHide()
        focusContext = .controlBar
        model.controlsVisible = true
        model.controlBarVisible = true
        setSurfaceRecognizers(enabled: false)
        controlBarHost?.view.isUserInteractionEnabled = true
        playerInputView?.allowsFocus = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Returns focus to the scrub surface (Up / Menu from the control-bar root),
    /// re-enabling scrub gestures and letting the transport auto-hide.
    private func exitToSurface() {
        guard focusContext == .controlBar else { return }
        focusContext = .surface
        model.controlBarVisible = false
        controlBarHost?.view.isUserInteractionEnabled = false
        playerInputView?.allowsFocus = true
        setSurfaceRecognizers(enabled: true)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        scheduleAutoHide()
    }

    private func setSurfaceRecognizers(enabled: Bool) {
        for recognizer in surfaceRecognizers { recognizer.isEnabled = enabled }
    }

    /// The bottom control bar always has at least the Diagnostics toggle, so
    /// entering it is always meaningful.
    private var hasControlBarContent: Bool { true }

    deinit {
        autoHideTask?.cancel()
        thumbnailTask?.cancel()
        refreshTask?.cancel()
        skipHintTask?.cancel()
    }
}
#endif
