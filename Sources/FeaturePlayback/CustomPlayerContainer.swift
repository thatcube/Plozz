#if canImport(UIKit)
import UIKit
import SwiftUI
import AVFoundation
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

/// SwiftUI bridge to the custom player: an `AVPlayerLayer` video surface with a
/// SwiftUI controls overlay on top and all Siri Remote input handled in UIKit
/// (the only reliable way to get analog touch-surface scrubbing on tvOS).
struct CustomPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer?
    let model: PlayerControlsModel
    let actions: PlayerActions
    let trickplay: TrickplayManifest?
    let themePalette: ThemePaletteBox

    func makeUIViewController(context: Context) -> PlayerInputViewController {
        let controller = PlayerInputViewController(model: model, actions: actions)
        controller.configureTrickplay(trickplay)
        controller.attachOverlay(themePalette: themePalette)
        controller.setPlayer(player)
        return controller
    }

    func updateUIViewController(_ controller: PlayerInputViewController, context: Context) {
        controller.actions = actions
        controller.setPlayer(player)
    }
}

/// A lightweight box so the SwiftUI `ThemePalette` (a CoreUI type) can cross the
/// representable boundary without FeaturePlayback's UIKit layer depending on it
/// structurally; the overlay uses it directly.
struct ThemePaletteBox {
    let makeOverlay: (PlayerControlsModel) -> AnyView
}

/// The video surface: a UIView whose backing layer is the `AVPlayerLayer`, made
/// focusable so it receives Siri Remote presses and indirect-touch pans.
final class PlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override var canBecomeFocused: Bool { true }
}

/// Owns the video layer, the SwiftUI controls overlay, and every Siri Remote
/// gesture. Scrubbing is preview-only — the underlying `AVPlayer` is never
/// seeked until the viewer commits (Select), so the scrub stays perfectly
/// smooth regardless of stream/seek latency.
final class PlayerInputViewController: UIViewController {
    var actions: PlayerActions
    private let model: PlayerControlsModel
    private var thumbnailLoader: TrickplayThumbnailLoader?
    private var overlayHost: UIHostingController<AnyView>?

    private var autoHideTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var scrubBaseSeconds: TimeInterval = 0
    private var resumeAfterScrub = false

    init(model: PlayerControlsModel, actions: PlayerActions) {
        self.model = model
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var surfaceView: PlayerSurfaceView { view as! PlayerSurfaceView }

    override func loadView() {
        view = PlayerSurfaceView()
        view.backgroundColor = .black
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        surfaceView.playerLayer.videoGravity = .resizeAspect
        installGestures()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Make sure the video surface owns the focus so the Siri Remote's
        // presses and indirect-touch pans reach our gesture recognizers.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        // Briefly reveal the transport on entry, then let it auto-hide.
        flashControls()
    }

    override var canBecomeFirstResponder: Bool { true }

    func configureTrickplay(_ manifest: TrickplayManifest?) {
        if let manifest, manifest.isUsable {
            thumbnailLoader = TrickplayThumbnailLoader(manifest: manifest)
        }
    }

    func attachOverlay(themePalette: ThemePaletteBox) {
        let host = UIHostingController(rootView: themePalette.makeOverlay(model))
        host.view.backgroundColor = .clear
        // Presentational only — never let the overlay steal remote focus from
        // the video surface that drives scrubbing.
        host.view.isUserInteractionEnabled = false
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        overlayHost = host
    }

    func setPlayer(_ player: AVPlayer?) {
        guard surfaceView.playerLayer.player !== player else { return }
        surfaceView.playerLayer.player = player
    }

    // MARK: Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [surfaceView] }

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
    }
}
#endif
