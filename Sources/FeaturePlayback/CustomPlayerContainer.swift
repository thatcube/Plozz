#if canImport(UIKit)
import UIKit
import SwiftUI
import CoreModels

/// Callbacks the input controller invokes on the owning view model. Kept as a
/// plain value of closures so the UIKit layer never imports the view model.
@MainActor
struct PlayerActions {
    var seek: (TimeInterval) -> Void = { _ in }
    var togglePlayPause: () -> Void = {}
    var selectAudio: (Int) -> Void = { _ in }
    var selectSubtitle: (Int) -> Void = { _ in }
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
    let trickplay: TrickplayManifest?
    let themePalette: ThemePaletteBox

    func makeUIViewController(context: Context) -> PlayerInputViewController {
        let controller = PlayerInputViewController(engine: engine, model: model, actions: actions)
        controller.configureTrickplay(trickplay)
        controller.attachVideoSurface()
        controller.attachOverlay(themePalette: themePalette)
        return controller
    }

    func updateUIViewController(_ controller: PlayerInputViewController, context: Context) {
        controller.actions = actions
    }
}

/// A lightweight box so the SwiftUI `ThemePalette` (a CoreUI type) can cross the
/// representable boundary without FeaturePlayback's UIKit layer depending on it
/// structurally; the overlay uses it directly.
struct ThemePaletteBox {
    let makeOverlay: (PlayerControlsModel) -> AnyView
}

/// The focusable root view that receives Siri Remote presses and indirect-touch
/// pans. The engine's video surface and the controls overlay are added as
/// non-interactive subviews, so focus always stays here.
final class PlayerInputView: UIView {
    override var canBecomeFocused: Bool { true }
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
    private var thumbnailLoader: TrickplayThumbnailLoader?
    private var overlayHost: UIHostingController<AnyView>?

    private var autoHideTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var scrubBaseSeconds: TimeInterval = 0
    private var resumeAfterScrub = false

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
        // Briefly reveal the transport on entry, then let it auto-hide.
        flashControls()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTask?.cancel()
        refreshTask = nil
    }

    override var canBecomeFirstResponder: Bool { true }

    func configureTrickplay(_ manifest: TrickplayManifest?) {
        if let manifest, manifest.isUsable {
            thumbnailLoader = TrickplayThumbnailLoader(manifest: manifest)
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

    func attachOverlay(themePalette: ThemePaletteBox) {
        let host = UIHostingController(rootView: themePalette.makeOverlay(model))
        host.view.backgroundColor = .clear
        // Presentational only — never let the overlay steal remote focus from
        // the input surface that drives scrubbing.
        host.view.isUserInteractionEnabled = false
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        overlayHost = host
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
        let duration = engine.duration
        if duration > 0 { model.duration = duration }
        // Don't fight the scrub head or an in-flight committed seek.
        if !model.isScrubbing && !model.isSeeking {
            model.currentSeconds = engine.currentTime
        }
        model.bufferedSeconds = engine.bufferedPosition
        model.isPaused = engine.isPaused
    }

    // MARK: Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [view] }

    // MARK: Gestures

    private func installGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)

        addPress(.select, #selector(handleSelect))
        addPress(.playPause, #selector(handlePlayPause))
        addPress(.menu, #selector(handleMenu))
        addPress(.leftArrow, #selector(handleLeft))
        addPress(.rightArrow, #selector(handleRight))

        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
        swipeDown.direction = .down
        swipeDown.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(swipeDown)
    }

    private func addPress(_ type: UIPress.PressType, _ action: Selector) {
        let recognizer = UITapGestureRecognizer(target: self, action: action)
        recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(recognizer)
    }

    // MARK: Scrubbing

    private var scrubSensitivitySeconds: TimeInterval {
        // A full touch-surface swipe covers ~15% of the runtime, clamped so it's
        // neither uselessly fine on long films nor jumpy on short clips. Edge
        // clicks (left/right) handle big ±10s skips.
        max(60, min(model.duration * 0.15, 300))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard model.duration > 0 else { return }
        switch gesture.state {
        case .began:
            if !model.isScrubbing { beginScrub() }
            scrubBaseSeconds = model.scrubSeconds
        case .changed:
            let width = max(1, view.bounds.width)
            let delta = (gesture.translation(in: view).x / width) * scrubSensitivitySeconds
            model.scrubSeconds = min(max(0, scrubBaseSeconds + delta), model.duration)
            updatePreviewThumbnail()
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
        model.isScrubbing = false
        model.previewImage = nil
        actions.seek(target)
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
        guard let loader = thumbnailLoader else { return }
        let seconds = model.scrubSeconds
        // Instant swap when the tile is already cached (the common case while
        // dragging within one tile) keeps scrubbing fluid; otherwise fetch async.
        if let cached = loader.cachedThumbnail(forSeconds: seconds) {
            model.previewImage = cached
            return
        }
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            let image = await loader.thumbnail(forSeconds: seconds)
            guard let self, !Task.isCancelled, self.model.isScrubbing else { return }
            // Only apply if the scrub head hasn't moved to a different thumbnail.
            if self.model.scrubSeconds == seconds || abs(self.model.scrubSeconds - seconds) < 0.001 {
                self.model.previewImage = image
            }
        }
    }

    // MARK: Button handlers

    @objc private func handleSelect() {
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

    @objc private func handleLeft() { skip(by: -10) }
    @objc private func handleRight() { skip(by: 10) }

    private func skip(by seconds: TimeInterval) {
        guard model.duration > 0 else { return }
        if model.isScrubbing {
            model.scrubSeconds = min(max(0, model.scrubSeconds + seconds), model.duration)
            updatePreviewThumbnail()
        } else {
            let target = min(max(0, model.currentSeconds + seconds), model.duration)
            actions.seek(target)
            flashControls()
        }
    }

    @objc private func handleSwipeDown() {
        guard !model.isScrubbing else { return }
        presentOptionsMenu()
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
            if !self.model.isScrubbing && !self.model.isPaused {
                self.model.controlsVisible = false
            }
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // MARK: Track menu

    private func presentOptionsMenu() {
        let hasAudio = model.hasSelectableAudio
        let hasSubs = model.hasSelectableSubtitles
        guard hasAudio || hasSubs else { return }

        if hasAudio && hasSubs {
            let sheet = UIAlertController(title: "Options", message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Audio", style: .default) { [weak self] _ in
                self?.presentTrackMenu(title: "Audio", options: self?.model.audioOptions ?? [], select: { self?.actions.selectAudio($0) })
            })
            sheet.addAction(UIAlertAction(title: "Subtitles", style: .default) { [weak self] _ in
                self?.presentTrackMenu(title: "Subtitles", options: self?.model.subtitleOptions ?? [], select: { self?.actions.selectSubtitle($0) })
            })
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(sheet, animated: true)
        } else if hasAudio {
            presentTrackMenu(title: "Audio", options: model.audioOptions, select: { [weak self] in self?.actions.selectAudio($0) })
        } else {
            presentTrackMenu(title: "Subtitles", options: model.subtitleOptions, select: { [weak self] in self?.actions.selectSubtitle($0) })
        }
    }

    private func presentTrackMenu(title: String, options: [PlayerTrackOption], select: @escaping (Int) -> Void) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for option in options {
            let label = option.isSelected ? "✓  \(option.title)" : option.title
            sheet.addAction(UIAlertAction(title: label, style: .default) { _ in select(option.id) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    deinit {
        autoHideTask?.cancel()
        thumbnailTask?.cancel()
        refreshTask?.cancel()
    }
}
#endif
