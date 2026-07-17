#if canImport(UIKit)
import UIKit
import SwiftUI
import QuartzCore
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
    /// Pick the second (dual) subtitle track by option id, or `offID` for off.
    var selectSecondarySubtitle: (Int) -> Void = { _ in }
    var setPlaybackSpeed: (Double) -> Void = { _ in }
    var setAudioDelay: (TimeInterval) -> Void = { _ in }
    var setSubtitleDelay: (TimeInterval) -> Void = { _ in }
    var setDialogEnhance: (Bool) -> Void = { _ in }
    /// Apply an edited subtitle appearance (in-player Style screen), for live
    /// preview + persistence.
    var setSubtitleStyle: (SubtitleStyle) -> Void = { _ in }
    /// Search the server's subtitle source for the given language (nil = preferred).
    var searchRemoteSubtitles: (String?) -> Void = { _ in }
    /// Re-run the last subtitle search (e.g. after a per-search preference change).
    var refreshRemoteSubtitleSearch: () -> Void = {}
    /// Download the chosen remote subtitle and hot-load it into the player.
    var downloadRemoteSubtitle: (RemoteSubtitle) -> Void = { _ in }
    /// Advance to the next episode (Info card → Next Episode).
    var playNextEpisode: () -> Void = {}
    /// Return to the previous episode (Info card → Previous).
    var playPreviousEpisode: () -> Void = {}
    /// Restart the current item from the beginning (Info card → Restart).
    var restart: () -> Void = {}
    /// Seek past the active intro/credits segment (Skip button Select).
    var skipSegment: () -> Void = {}
    /// Auto-seek past the active segment (no button) when Auto-skip is enabled.
    var autoSkipSegment: () -> Void = {}
    /// Dismiss the skip button without seeking (Menu / swipe away).
    var dismissSkip: () -> Void = {}
    /// Advance to the next episode (Up Next card Play / auto-advance). Routed
    /// through an in-place VM swap so the full-screen cover never flashes.
    var playUpNext: () -> Void = {}
    /// Dismiss the Up Next card without advancing (Menu / swipe away).
    var dismissUpNext: () -> Void = {}
    var dismiss: () -> Void = {}
}

/// The shared, **engine-agnostic** custom player UI: it hosts whatever bare video
/// surface the active `VideoEngine` vends (`makeVideoOutputView()`), layers a
/// SwiftUI controls overlay on top, and handles all Siri Remote input in UIKit
/// (the only reliable way to get analog touch-surface scrubbing on tvOS). It
/// drives playback purely through the `VideoEngine` protocol and the
/// `PlayerActions` closures, so any engine (AVPlayer or Plozzigen)
/// reuses it without change.
struct CustomPlayerContainer: UIViewControllerRepresentable {
    let engine: any VideoEngine
    let model: PlayerControlsModel
    let subtitleModel: LiveSubtitleModel
    let actions: PlayerActions
    let scrubPreview: ScrubPreviewSource?
    let authenticatedHTTPResolver:
        (any AuthenticatedHTTPResourceResolving)?
    let themePalette: ThemePaletteBox

    func makeUIViewController(context: Context) -> PlayerInputViewController {
        let controller = PlayerInputViewController(engine: engine, model: model, actions: actions)
        controller.configureScrubPreview(
            scrubPreview,
            authenticatedHTTPResolver: authenticatedHTTPResolver
        )
        controller.attachVideoSurface()
        controller.attachSubtitleOverlay(subtitleModel)
        controller.attachControls(themePalette: themePalette)
        return controller
    }

    func updateUIViewController(_ controller: PlayerInputViewController, context: Context) {
        controller.actions = actions
    }
}

/// Minimal, controls-free host for an engine's bare video surface. Used during
/// loading so engines that require an attached/windowed render target
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
    /// active segment; `onDismiss` hides it without seeking; `onPlayPause` toggles
    /// playback while the button holds focus (so Play/Pause still works there, and
    /// the countdown ring freezes in place because it tracks playback position).
    /// `onSkip`/`onDismiss` also return focus to the scrub surface (the controller
    /// owns that transition).
    let makeSkipButton: (PlayerControlsModel, @escaping () -> Void, @escaping () -> Void, @escaping () -> Void) -> AnyView
    /// Builds the focusable Up Next card shown during the closing credits when a
    /// next episode is queued. `onPlayNext` advances to it (in-place VM swap);
    /// `onDismiss` hides the card without advancing; `onPlayPause` toggles playback
    /// while the card holds focus (the auto-advance ring freezes in place because
    /// it tracks playback position). `onPlayNext`/`onDismiss` return focus to the
    /// scrub surface (the controller owns that transition).
    let makeUpNextCard: (PlayerControlsModel, @escaping () -> Void, @escaping () -> Void, @escaping () -> Void) -> AnyView
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
    /// Interprets Siri-Remote pan samples into scrub decisions (axis lock,
    /// pause-to-seek gate, velocity smoothing, flick-vs-land commit). Owns the
    /// per-gesture state that used to live inline in `handlePan`; the point→
    /// seconds math stays in ``ScrubGeometry`` and the side effects stay here.
    private var scrubGesture = ScrubGestureInterpreter()
    private var resumeAfterScrub = false

    /// Pending debounced commit for a *flick*-ended scrub. A fast flick lift
    /// keeps the scrub session alive instead of seeking immediately, so a quick
    /// follow-up swipe can cancel this and continue the same session — turning a
    /// multi-swipe traversal into one fluid scrub that seeks (and resumes) only
    /// once, instead of fighting a seek + rebuffer + play/pause on every swipe.
    private var scrubCommitTask: Task<Void, Never>?
    /// How long after a flick lift to wait for a follow-up swipe before
    /// committing. Long enough to bridge the gap between rapid swipes, short
    /// enough that a final flick still lands without a noticeable delay.
    private let scrubFlickBridgeWindow: TimeInterval = 0.3

    /// Env-gated (`SCRUB_DIAG=1`) per-scrub smoothness probe — measures display
    /// hitches, pan-sample cadence, per-sample handler cost, and thumbnail cache
    /// hit/miss, emitting one `PLZSCRUB` line per scrub for off-device capture.
    private let scrubDiag = ScrubDiagnostics()

    /// Suppresses the tvOS screensaver / Apple TV sleep while video is actively
    /// playing, and releases it the instant playback pauses, ends, or this host
    /// goes away. Driven every refresh tick off `engine.preventsDisplaySleep`, so
    /// it behaves identically for every engine/decoder (AVPlayer *and* Plozzigen).
    private let idleSleepGuard = IdleSleepGuard()

    /// Whether the Siri Remote currently drives the scrub surface or the bottom
    /// control bar. In `.controlBar` the surface gesture recognizers are disabled
    /// so the SwiftUI focus engine owns navigation.
    private enum FocusContext { case surface, controlBar, skipButton, upNext }
    private var focusContext: FocusContext = .surface

    /// The always-attached, focusable bottom control bar. It only takes focus
    /// while `focusContext == .controlBar`.
    private var controlBarHost: UIHostingController<AnyView>?

    /// The always-attached Skip Intro/Credits button overlay. Interactive (and
    /// focused) only while `focusContext == .skipButton`; collapses to nothing
    /// when no segment is active. Tracked so presentation only flips on change.
    private var skipButtonHost: UIHostingController<AnyView>?
    private var presentingSkipButton = false
    /// The always-attached Up Next card overlay (closing-credits next-episode
    /// affordance). Interactive/focused only while `focusContext == .upNext`;
    /// collapses to nothing when no next episode / not in credits. Shares the
    /// lower-right slot with the Skip button — they never present together.
    private var upNextHost: UIHostingController<AnyView>?
    private var presentingUpNext = false
    /// In `.autoDelay`, the playback position (seconds) at which the presented Up
    /// Next card auto-advances to the next episode. `nil` outside an active delay.
    private var upNextAdvanceAtSeconds: TimeInterval?
    /// In `.autoDelay`, the playback position (seconds) at which the presented
    /// Skip button auto-skips. Tied to playback position (not wall-clock) so the
    /// countdown pauses with the video. `nil` outside an active delay.
    private var autoSkipAtSeconds: TimeInterval?

    /// Surface gesture recognizers we toggle off while the control bar owns focus.
    private var surfaceRecognizers: [UIGestureRecognizer] = []

    /// Hosts the owned subtitle overlay above the video surface and below the
    /// transport controls. Present for the player's lifetime; renders nothing
    /// until the view model loads a cue stream into `subtitleModel`.
    private var subtitleOverlayHost: UIHostingController<LiveSubtitleOverlay>?
    private var subtitleModel: LiveSubtitleModel?
    /// Drives the subtitle timeline off the engine clock every frame. The model
    /// only republishes on cue-boundary crossings, so this stays cheap.
    private var subtitleClock: CADisplayLink?

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
        startSubtitleClock()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
        cancelScrubCommit()
        if ScrubDiagnostics.forceScrubRefresh { engine.setScrubRefreshBoost(false) }
        subtitleClock?.invalidate()
        subtitleClock = nil
        // Leaving playback: let the screensaver / Apple TV sleep resume.
        idleSleepGuard.allowSleep()
    }

    override var canBecomeFirstResponder: Bool { true }

    func configureScrubPreview(
        _ source: ScrubPreviewSource?,
        authenticatedHTTPResolver:
            (any AuthenticatedHTTPResourceResolving)?
    ) {
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
            thumbnailLoader = TrickplayThumbnailLoader(
                manifest: manifest,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
            PlozzLog.playback.debug(
                "Configured Jellyfin tiled scrub preview (\(manifest.tileResources.count) tiles, intervalMs=\(manifest.intervalMs))"
            )
        case .plexBIF(let resource):
            thumbnailLoader = PlexBIFThumbnailLoader(
                resource: resource,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
            PlozzLog.playback.debug("Configured Plex BIF scrub preview")
        }
        prefetchThumbnailsSoon()
    }

    /// Warms the trickplay source (e.g. downloads the Plex BIF blob) a beat after
    /// it's configured, so the first scrub already has previews instead of feeling
    /// like it's fighting an empty timeline while the data loads. Delayed slightly
    /// so initial video buffering gets first claim on bandwidth.
    private func prefetchThumbnailsSoon() {
        let loader = thumbnailLoader
        guard loader != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.thumbnailLoader === loader else { return }
            loader?.prefetch()
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

    /// Mounts the owned subtitle overlay directly above the video surface (and
    /// below the transport controls, which are attached afterwards). The overlay
    /// is non-interactive so Siri Remote pans still reach the scrub surface. A
    /// display-link then drives the cue timeline off the engine clock.
    func attachSubtitleOverlay(_ model: LiveSubtitleModel) {
        subtitleModel = model
        let host = UIHostingController(rootView: LiveSubtitleOverlay(model: model))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(host)
        // Index 1: above the video surface (index 0), below the controls/skip
        // hosts that `attachControls` adds on top afterwards.
        view.insertSubview(host.view, at: 1)
        host.didMove(toParent: self)
        subtitleOverlayHost = host
    }

    /// Starts the per-frame subtitle clock. Cheap when no cues are loaded (the
    /// model no-ops) and when a line is held (no boundary crossing → no publish).
    private func startSubtitleClock() {
        subtitleClock?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tickSubtitleClock))
        link.add(to: .main, forMode: .common)
        subtitleClock = link
    }

    @objc private func tickSubtitleClock() {
        subtitleModel?.tick(engine.currentTime)
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
            togglePlayPause: { [weak self] in self?.actions.togglePlayPause() },
            selectAudio: { [weak self] in self?.actions.selectAudio($0) },
            selectSubtitle: { [weak self] in self?.actions.selectSubtitle($0) },
            selectSecondarySubtitle: { [weak self] in self?.actions.selectSecondarySubtitle($0) },
            setPlaybackSpeed: { [weak self] in self?.actions.setPlaybackSpeed($0) },
            setAudioDelay: { [weak self] in self?.actions.setAudioDelay($0) },
            setSubtitleDelay: { [weak self] in self?.actions.setSubtitleDelay($0) },
            setDialogEnhance: { [weak self] in self?.actions.setDialogEnhance($0) },
            setSubtitleStyle: { [weak self] in self?.actions.setSubtitleStyle($0) },
            searchRemoteSubtitles: { [weak self] in self?.actions.searchRemoteSubtitles($0) },
            refreshRemoteSubtitleSearch: { [weak self] in self?.actions.refreshRemoteSubtitleSearch() },
            downloadRemoteSubtitle: { [weak self] in self?.actions.downloadRemoteSubtitle($0) },
            playNextEpisode: { [weak self] in self?.actions.playNextEpisode() },
            playPreviousEpisode: { [weak self] in self?.actions.playPreviousEpisode() },
            restart: { [weak self] in self?.actions.restart() }
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
                { [weak self] in self?.dismissSkipButton() },
                { [weak self] in self?.togglePlayPauseFromOverlay() }
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

        // Up Next card on top of the control bar, sharing the lower-right slot
        // with the Skip button. Off until the closing-credits window opens with a
        // next episode queued and the viewer is on the scrub surface.
        let upNextCardHost = UIHostingController(
            rootView: themePalette.makeUpNextCard(
                model,
                { [weak self] in self?.playUpNext() },
                { [weak self] in self?.dismissUpNextCard() },
                { [weak self] in self?.togglePlayPauseFromOverlay() }
            )
        )
        upNextCardHost.view.backgroundColor = .clear
        upNextCardHost.view.isUserInteractionEnabled = false
        addChild(upNextCardHost)
        upNextCardHost.view.frame = view.bounds
        upNextCardHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(upNextCardHost.view)
        upNextCardHost.didMove(toParent: self)
        upNextHost = upNextCardHost
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
                // Poll fast while a committed seek is settling so the bar
                // releases its optimistic pin and resumes mirroring engine time
                // the instant the seek lands — that's what makes a seek feel like
                // it "sticks" immediately. Relax to a cheaper cadence during
                // steady playback, where a tighter loop buys nothing.
                let settling = (self?.model.pendingSeekTarget != nil)
                let interval: UInt64 = settling ? 60_000_000 : 250_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func refreshFromEngine() {
        // Keep the display awake only while frames are actually advancing.
        // Evaluated every tick, before any early-return, so a pause, end-of-
        // stream, or stall promptly releases the wake lock for every engine.
        idleSleepGuard.keepAwake(engine.preventsDisplaySleep)
        let resolution = PlaybackClockReconciler.reconcile(
            snapshot: .init(
                currentTime: engine.currentTime,
                duration: engine.duration,
                bufferedPosition: engine.bufferedPosition,
                isPaused: engine.isPaused),
            isScrubbing: model.isScrubbing,
            pendingSeekTarget: model.pendingSeekTarget,
            isResumeConfirming: model.isResumeConfirming)

        if let duration = resolution.duration { model.duration = duration }
        if resolution.clearPendingSeek { model.pendingSeekTarget = nil }
        if let currentSeconds = resolution.currentSeconds { model.currentSeconds = currentSeconds }
        if let bufferedSeconds = resolution.bufferedSeconds { model.bufferedSeconds = bufferedSeconds }
        if let isPaused = resolution.isPaused { model.isPaused = isPaused }

        if resolution.shouldEvaluateSkip { evaluateSkipPresentation() }
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
        // Clear a stale seek-landing once the live position leaves its segment, so
        // a later NATURAL re-entry into the same segment isn't still treated as a
        // seek (which would otherwise keep suppressing it / forcing manual-only).
        if let landing = model.seekLanding,
           model.skippableSegments.activeSkippable(at: model.currentSeconds)?.id != landing.segmentID {
            model.seekLanding = nil
        }

        // Up Next takes priority over Skip Credits in the shared lower-right slot:
        // when a next episode is queued during the closing credits, the card
        // supersedes the (pointless) Skip Credits button. Resolve it first; when
        // it owns the slot, ensure the Skip button is torn down and stop here.
        if model.upNextActive {
            if presentingSkipButton { exitSkipButton() }
            presentUpNextIfNeeded()
            return
        }
        // Up Next isn't active — make sure its card is dismissed before the Skip
        // button (or nothing) takes the slot.
        if presentingUpNext { exitUpNext() }

        // Credits owned by Up Next (next episode queued) never fall back to a Skip
        // Credits button — once the card is dismissed (or while auto-instant
        // advances) the slot stays empty, so the two affordances never both show.
        if model.creditsOwnedByUpNext {
            if presentingSkipButton { exitSkipButton() }
            return
        }

        guard model.activeSkipSegment != nil else {
            if presentingSkipButton { exitSkipButton() }
            return
        }

        // A seek that landed in the segment's opening grace window offers a manual
        // button only — never auto-skip, never a countdown, never a focus-steal —
        // so a deliberate seek is never hijacked. (A *deep* seek already cleared
        // `activeSkipSegment` above.) Skip OFF suppresses it, and scrubbing / an
        // off-surface focus always defers. The branching lives in the pure
        // `SkipPresentationDecision` so those rules are unit-tested directly.
        let deadlineReached = autoSkipAtSeconds.map { model.currentSeconds >= $0 } ?? false
        switch SkipPresentationDecision.action(
            skipMode: model.skipMode,
            wasSeekEntered: model.activeSkipWasSeekEntered,
            presentingButton: presentingSkipButton,
            focusIsSurface: focusContext == .surface,
            isScrubbing: model.isScrubbing,
            autoDelayDeadlineReached: deadlineReached
        ) {
        case .tearDownIfPresenting:
            if presentingSkipButton { exitSkipButton() }
        case let .presentManual(stealFocus):
            enterSkipButton(stealFocus: stealFocus)
        case .autoInstant:
            actions.autoSkipSegment()
        case .beginAutoDelay:
            autoSkipAtSeconds = model.currentSeconds + SkipIntrosMode.autoSkipDelay
            model.autoSkipAtSeconds = autoSkipAtSeconds
            enterSkipButton()
        case .fireAutoDelay:
            autoSkipFromDelay()
        case .none:
            break
        }
    }

    private func enterSkipButton(stealFocus: Bool = true) {
        presentingSkipButton = true
        model.isPresentingSkipButton = true
        guard stealFocus else {
            // Passive present (a grace-window seek landed here): the button is
            // visible but the scrub surface keeps focus and stays fully
            // interactive, so the seek is never hijacked. An Up press grabs the
            // button (see `handleUp`) for viewers who do want to skip.
            return
        }
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
        model.isPresentingSkipButton = false
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

    /// Play/Pause pressed while the Skip button or Up Next card holds focus.
    /// Toggle playback in place — do NOT leave the focus context or reveal the
    /// transport bar — so the affordance stays put. The countdown ring freezes on
    /// its own because it's driven by playback position, which stops while paused.
    private func togglePlayPauseFromOverlay() {
        actions.togglePlayPause()
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

    // MARK: Up Next card presentation

    /// Presents, auto-advances, or holds the Up Next card during the closing
    /// credits, mirroring the Skip affordance's per-mode behaviour but advancing
    /// to the *next episode* (an in-place VM swap — never a seek-to-end, so the
    /// next episode never flashes the series page):
    ///  * `.on` / `.off` — present the focusable card (manual Play Next).
    ///  * `.autoDelay` — present the card, then advance once playback reaches the
    ///    deadline (the card's ring counts the wait down; swipe-up cancels).
    ///  * `.autoInstant` — advance immediately, no card (binge).
    /// A grace-window seek into credits presents the card passively (no auto, no
    /// focus-steal); a deep seek suppressed `upNextActive` entirely upstream.
    private func presentUpNextIfNeeded() {
        let deadlineReached = upNextAdvanceAtSeconds.map { model.currentSeconds >= $0 } ?? false
        switch UpNextPresentationDecision.action(
            skipMode: model.skipMode,
            wasSeekEntered: model.activeSkipWasSeekEntered,
            presentingCard: presentingUpNext,
            focusIsSurface: focusContext == .surface,
            isScrubbing: model.isScrubbing,
            autoDelayDeadlineReached: deadlineReached
        ) {
        case .none:
            break
        case .presentPassive:
            enterUpNext(stealFocus: false)
        case .presentManual:
            enterUpNext()
        case .beginAutoDelay:
            upNextAdvanceAtSeconds = model.currentSeconds + SkipIntrosMode.autoSkipDelay
            model.upNextAdvanceAtSeconds = upNextAdvanceAtSeconds
            enterUpNext()
        case .advance:
            advanceToUpNext()
        }
    }

    private func enterUpNext(stealFocus: Bool = true) {
        presentingUpNext = true
        model.isPresentingUpNext = true
        guard stealFocus else {
            // Passive present (a grace-window seek landed in credits): the card is
            // visible but the scrub surface keeps focus, so the seek is never
            // hijacked. An Up press grabs the card (see `handleUp`).
            return
        }
        focusContext = .upNext
        hideControls()
        setSurfaceRecognizers(enabled: false)
        upNextHost?.view.isUserInteractionEnabled = true
        playerInputView?.allowsFocus = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Returns focus to the scrub surface after the Up Next card is used,
    /// dismissed, or its credits window passes.
    private func exitUpNext() {
        presentingUpNext = false
        model.isPresentingUpNext = false
        upNextAdvanceAtSeconds = nil
        model.upNextAdvanceAtSeconds = nil
        upNextHost?.view.isUserInteractionEnabled = false
        if focusContext == .upNext {
            focusContext = .surface
            playerInputView?.allowsFocus = true
            setSurfaceRecognizers(enabled: true)
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    /// Up Next card Select / auto-delay deadline: advance to the next episode.
    /// Marks the card consumed so a per-tick auto mode (instant/delay) fires this
    /// exactly once and never re-summons anything for the same credits window.
    private func advanceToUpNext() {
        model.dismissedUpNext = true
        actions.playUpNext()
        exitUpNext()
    }

    /// Up Next card Menu / swipe-up: hide without advancing, return to surface.
    private func dismissUpNextCard() {
        actions.dismissUpNext()
        exitUpNext()
    }

    /// Up Next card Select via the surface passive-present path (Up grab).
    private func playUpNext() {
        advanceToUpNext()
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
        if focusContext == .upNext, let upNextHost {
            return [upNextHost.view]
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

    private var scrubTuning: ScrubGeometry.Tuning {
        // Base seconds-per-point scales with runtime so the *fraction* of the
        // content a swipe covers stays consistent across lengths — a fast flick
        // crosses the same percentage of a 5-min clip as a 2h film. The reference
        // is a 2h film (scale 1.0 → ~0.18 s/pt). The floor is kept very low (0.05,
        // ≈ a 6-min runtime) purely to stop sub-minute clips from scrubbing
        // imperceptibly; above that it's pure fraction-consistency. Lowering the
        // base on short content also makes fine drags there *finer*, never
        // coarser, so the precise slow-finger feel is preserved everywhere. A fast
        // flick accelerates up to maxAccelMultiplier via a smoothstep curve (see
        // ScrubGeometry); the ceiling is modest so flicks stay controllable.
        let durationScale = min(max(model.duration / 7200, 0.05), 1.6)
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
            scrubGesture.begin()
        case .changed:
            let translation = gesture.translation(in: view)
            let sampleStart = ScrubDiagnostics.enabled ? CACurrentMediaTime() : 0
            let outcome = scrubGesture.changed(
                translationX: Double(translation.x),
                translationY: Double(translation.y),
                velocityX: Double(gesture.velocity(in: view).x),
                isScrubbing: model.isScrubbing,
                seekWithoutPausing: model.seekWithoutPausing,
                isPaused: model.isPaused)
            switch outcome {
            case .ignore:
                break
            case .enterControlBar:
                // A deliberate downward swipe reveals the controls and drops focus
                // into the bottom button row.
                enterControlBar()
            case .flashAndSuppress:
                // Pause-to-seek gate: flash the transport for feedback only.
                flashControls()
            case let .advance(deltaPoints, smoothedSpeed, beginScrub, continueTraversal):
                // Continuing a flick-bridged traversal cancels the pending commit
                // and keeps scrubbing (momentum carried in the interpreter).
                if continueTraversal { cancelScrubCommit() }
                if beginScrub { self.beginScrub() }
                model.scrubSeconds = ScrubGeometry.advance(
                    scrubSeconds: model.scrubSeconds,
                    translationDeltaPoints: deltaPoints,
                    speedPointsPerSecond: smoothedSpeed,
                    tuning: scrubTuning,
                    duration: model.duration)
                let cacheHit = updatePreviewThumbnail()
                if ScrubDiagnostics.enabled {
                    scrubDiag.recordSample(
                        handlerMs: (CACurrentMediaTime() - sampleStart) * 1000,
                        cacheHit: cacheHit)
                }
            }
        case .ended, .cancelled, .failed:
            // Auto-commit a horizontal scrub on lift, like Apple's own
            // AVPlayerViewController — but distinguish a deliberate landing
            // (commit + resume now) from a fast flick (keep the session alive and
            // bridge to the next swipe so we don't seek + rebuffer between swipes).
            switch scrubGesture.ended(
                gestureEnded: gesture.state == .ended,
                velocityX: Double(gesture.velocity(in: view).x),
                isScrubbing: model.isScrubbing) {
            case .none:
                break
            case .commit:
                commitScrub()
            case .bridgeCommit:
                scheduleScrubCommit()
            }
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
        ScrubDiagnostics.note("boost-call engine=\(type(of: engine)) force=\(ScrubDiagnostics.forceScrubRefresh)")
        if ScrubDiagnostics.forceScrubRefresh { engine.setScrubRefreshBoost(true) }
        scrubDiag.begin()
        updatePreviewThumbnail()
    }

    private func commitScrub() {
        guard model.isScrubbing else { return }
        // Any pending flick bridge is now resolved by this commit.
        cancelScrubCommit()
        let target = model.scrubSeconds
        // Commit the optimistic target BEFORE leaving scrub mode. While
        // scrubbing, `displaySeconds` reads `scrubSeconds` (== target); once
        // `isScrubbing` clears it reads `currentSeconds`. Seeking first makes
        // `requestSeek` set `currentSeconds = target` up front, so the handoff is
        // scrubSeconds(target) → currentSeconds(target) with no one-frame dip
        // back to the stale pre-scrub position.
        actions.seek(target)
        // Resolve playback intent BEFORE clearing `isScrubbing`. Clearing
        // `isScrubbing` un-hides the status glyph; if the resume ran *after* that
        // there'd be a frame where the overlay is visible while the begin-scrub
        // preview-pause is still in effect (isPaused && intendsPause), mounting the
        // pause glyph for one beat — it would animate in (scale+opacity) then
        // vanish as the resume + seek spinner took over (the flicker). Resuming
        // first means the pause branch never mounts: a seek-without-pausing shows
        // only the loading spinner.
        if resumeAfterScrub { actions.togglePlayPause() }
        model.isScrubbing = false
        model.previewImage = nil
        model.seekIndicatorOnLeft = false
        if ScrubDiagnostics.forceScrubRefresh { engine.setScrubRefreshBoost(false) }
        scrubDiag.end("commit")
        scheduleAutoHide()
    }

    /// Defers a flick-ended scrub's commit by `scrubFlickBridgeWindow`. If a
    /// follow-up swipe arrives first it cancels this (continuing the session);
    /// otherwise the timer fires and the scrub commits — seeking + resuming once
    /// the traversal has actually settled.
    private func scheduleScrubCommit() {
        scrubCommitTask?.cancel()
        let window = scrubFlickBridgeWindow
        scrubCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.scrubCommitTask = nil
            self.commitScrub()
        }
    }

    private func cancelScrubCommit() {
        scrubCommitTask?.cancel()
        scrubCommitTask = nil
    }

    private func cancelScrub() {
        guard model.isScrubbing else { return }
        // Resolve playback intent before un-hiding the overlay (same ordering
        // rationale as commitScrub) so the pause glyph never flickers in.
        if resumeAfterScrub { actions.togglePlayPause() }
        model.isScrubbing = false
        model.previewImage = nil
        if ScrubDiagnostics.forceScrubRefresh { engine.setScrubRefreshBoost(false) }
        scrubDiag.end("cancel")
        scheduleAutoHide()
    }

    @discardableResult
    private func updatePreviewThumbnail() -> Bool {
        guard let loader = thumbnailLoader else {
            model.previewImage = nil
            return true
        }
        let requestedSeconds = model.scrubSeconds
        // Instant swap when the tile is already cached (the common case while
        // dragging within one tile) keeps scrubbing fluid; otherwise fetch async.
        if let cached = loader.cachedThumbnail(forSeconds: requestedSeconds) {
            model.previewImage = cached
            return true
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
        return false
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
    /// focus off the surface, matching the swipe-up reveal. If a Skip button is
    /// currently showing passively (a grace-window seek landed in a segment), Up
    /// grabs it instead so the viewer can act on the affordance they chose not to
    /// have steal focus.
    @objc private func handleUp() {
        guard focusContext == .surface, !model.isScrubbing else { return }
        if presentingSkipButton, model.activeSkipSegment != nil {
            enterSkipButton(stealFocus: true)
            return
        }
        if presentingUpNext, model.upNextActive {
            enterUpNext(stealFocus: true)
            return
        }
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
        // A passively-presented Up Next card / Skip button shares the lower-right
        // slot while nothing is focused there. Entering the control bar opens a
        // menu, and the two must never co-exist (an unfocusable card over an open
        // menu is exactly what let Back exit the whole player). Tear the passive
        // present down here; it re-presents from `evaluateSkipPresentation` once
        // the bar closes back to the surface — "show it after the menus close".
        if presentingUpNext { exitUpNext() }
        if presentingSkipButton { exitSkipButton() }
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
