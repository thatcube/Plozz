#if os(iOS)
import AVKit
import Combine
import FeaturePlayback
import SwiftUI

/// Picture in Picture for the custom player.
///
/// Built by hand rather than inherited from `AVPlayerViewController`. Letting
/// AVKit own the player is the small-code route and it is what AetherPlayer
/// does, but it also brings Apple's chrome to *normal* playback, which would
/// replace the transport, scrub previews, subtitle styling and menus this app
/// has. The PiP window itself is system-drawn either way, so nothing is lost by
/// driving the controller directly.
///
/// Availability is a real question, not a formality: PiP presents from an
/// `AVPlayerLayer`, and the engine only has one on its native path. A software
/// -decoded source has no `AVPlayer`, so the button has to disappear rather than
/// fail when pressed.
@MainActor
final class PlozziOSPictureInPictureController: NSObject, ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isActive = false

    /// Called when the user restores from the PiP window, so the host can put the
    /// player back on screen if it was dismissed while PiP was running.
    var onRestoreUI: (() async -> Void)?

    private var controller: AVPictureInPictureController?
    private weak var engine: (any PictureInPicturePresentingEngine)?
    private var observations: Set<AnyCancellable> = []

    /// Binds to the engine's presenting layer. Safe to call repeatedly: the
    /// engine republishes its player across audio-track reloads, and a controller
    /// built against a stale layer stops working silently.
    func attach(engine: any PictureInPicturePresentingEngine) {
        var engine = engine
        self.engine = engine
        // Follow layer swaps rather than hoping some other state change happens
        // to re-trigger an attach. Starting AirPlay reloads the source against
        // the device's LAN address, which rebuilds the player and leaves this
        // controller holding a layer that is no longer on screen: the PiP button
        // silently disappeared until an unrelated phase change rebuilt it.
        engine.onPresentationLayerChanged = { [weak self] in
            self?.rebuild()
        }
        rebuild()
    }

    func detach() {
        engine?.onPresentationLayerChanged = nil
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller = nil
        engine = nil
        observations.removeAll()
        isAvailable = false
        isActive = false
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    private func rebuild() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let layer = engine?.pictureInPicturePlayerLayer() else {
            controller = nil
            isAvailable = false
            return
        }
        // Same layer as last time: keep the controller, otherwise starting PiP
        // would present from a surface that is no longer on screen.
        if let existing = controller, existing.playerLayer === layer {
            isAvailable = existing.isPictureInPicturePossible
            return
        }
        let built = AVPictureInPictureController(playerLayer: layer)
        built?.delegate = self
        // The system decides when an inline player is eligible; asking for it
        // means backgrounding the app continues playback in a window instead of
        // stopping, which is the behaviour people expect from a video app.
        built?.canStartPictureInPictureAutomaticallyFromInline = true
        controller = built
        observations.removeAll()
        built?.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] possible in self?.isAvailable = possible }
            .store(in: &observations)
    }

    /// Re-reads the engine's layer. Call when playback (re)starts: the layer does
    /// not exist until the native path has loaded.
    func refresh() {
        rebuild()
    }
}

extension PlozziOSPictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in
            isActive = true
            // The engine's background keepalive and its software-path subtitle
            // compositor both read this.
            engine?.setPictureInPictureActive(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in
            isActive = false
            engine?.setPictureInPictureActive(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            isActive = false
            engine?.setPictureInPictureActive(false)
        }
    }

    /// Fired when the user taps the PiP window's restore button. The completion
    /// handler must be called or AVKit leaves the window in a half-restored
    /// state, so it runs even when the host has nothing to put back.
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            await onRestoreUI?()
            completionHandler(true)
        }
    }
}
#endif
