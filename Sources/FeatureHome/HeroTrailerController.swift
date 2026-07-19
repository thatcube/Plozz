#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import CoreNetworking
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
import SwiftUI
#endif

/// Shared, app-level owner of the **hero trailer** — one muted (by default)
/// `AVPlayer` whose video layer is rendered by both the Home hero carousel and
/// the detail-page hero. Hoisting it above both surfaces (like
/// ``ThemeMusicController``) is what lets a trailer that started in the Home hero
/// keep playing when the user opens the detail page: only the foreground metadata
/// swaps; the same player keeps rolling behind it.
///
/// Deliberately bounded for memory safety (the Apple TV per-process ceiling is
/// unforgiving): exactly ONE `AVPlayer`, one in-flight item, torn down on stop.
/// The Home carousel only ever feeds it a **fast** (local / server-resolved)
/// trailer URL — never an on-device YouTube extraction — so it never spins up the
/// heavy JavaScriptCore path on the rotating hero.
@MainActor
@Observable
public final class HeroTrailerController {
    /// The item id whose trailer is currently loaded/playing (`nil` when idle).
    public private(set) var currentItemID: String?
    /// Whether a trailer item is actively playing (has begun, not ended/stopped).
    public private(set) var isPlaying = false
    /// The resolved trailer duration in seconds once known (`0` until ready).
    /// Drives the hero's dwell length so the progress bar spans the full trailer.
    public private(set) var duration: TimeInterval = 0

    /// The underlying player, exposed only so a ``HeroTrailerVideoLayer`` can
    /// attach an `AVPlayerLayer`. Engine-agnostic callers must not depend on it.
    public let player = AVPlayer()

    /// Fired on the main actor when the current trailer plays through to its end,
    /// so the hero can advance to the next item. Reset per load.
    public var onEnded: (@MainActor () -> Void)?

    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var hasStartedPlayback = false

    public init() {
        // Never let the trailer claim the Now-Playing transport or interrupt
        // music; it's ambient. Muting is applied per play() call.
        player.actionAtItemEnd = .pause
    }

    /// Whether this controller is already presenting `itemID` (so a hero→detail
    /// hand-off for the same title can keep playing rather than reload).
    public func isShowing(_ itemID: String) -> Bool {
        currentItemID == itemID && currentItemID != nil
    }

    /// Loads and plays `resolvedURL` as the trailer for `itemID`. No-op (keeps
    /// playing) if the same item is already showing. `muted` follows the profile's
    /// trailer-audio preference.
    public func play(itemID: String, resolvedURL: URL, muted: Bool) {
        if currentItemID == itemID, player.currentItem != nil {
            player.isMuted = muted
            return
        }

        stopPlayback(resetItem: false)
        activateSession()

        let item = AVPlayerItem(url: resolvedURL)
        player.isMuted = muted
        hasStartedPlayback = false
        duration = 0
        observeEnd(of: item)
        observeStatus(of: item)
        player.replaceCurrentItem(with: item)

        currentItemID = itemID
        PlozzLog.app.info("Hero trailer: queued item=\(itemID) muted=\(muted) url=\(PlozzLog.redact(url: resolvedURL))")
    }

    /// Applies a live mute change (e.g. the user flips the muted toggle) without
    /// reloading.
    public func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    /// Stops playback and releases the item. Called on navigate-away / advance /
    /// mode-off so the single player never lingers.
    public func stop() {
        guard isPlaying || currentItemID != nil else { return }
        stopPlayback(resetItem: true)
        PlozzLog.app.info("Hero trailer: stopped")
    }

    /// Stops only if the currently-loaded item is `itemID` (a scoped teardown so a
    /// stale view's disappear can't stop a trailer that already advanced).
    public func stop(ifShowing itemID: String) {
        guard currentItemID == itemID else { return }
        stop()
    }

    private func stopPlayback(resetItem: Bool) {
        hasStartedPlayback = false
        player.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        if resetItem {
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            currentItemID = nil
            duration = 0
        }
    }

    private func beginPlaybackIfReady() {
        guard !hasStartedPlayback else { return }
        hasStartedPlayback = true
        isPlaying = true
        player.seek(to: .zero)
        player.play()
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.onEnded?()
            }
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    self.beginPlaybackIfReady()
                case .failed:
                    let detail = item.error.map(String.init(describing:)) ?? "unknown"
                    PlozzLog.app.error("Hero trailer: failed error=\(detail)")
                    self.stop()
                default:
                    break
                }
            }
        }
    }

    private func activateSession() {
        #if !os(macOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // Mix so a muted trailer never disturbs other audio; a sound-on trailer
            // still coexists (and theme music is blocked separately at the app level).
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            PlozzLog.app.error("Hero trailer: audio session activation failed error=\(String(describing: error))")
        }
        #endif
    }
}

#if canImport(UIKit)
/// A thin `AVPlayerLayer`-backed surface fed by a ``HeroTrailerController``'s
/// player, so both the Home hero and the detail hero can render the *same* live
/// trailer. Purely a video sink — no controls, no transport UI.
public struct HeroTrailerVideoLayer: UIViewRepresentable {
    private let player: AVPlayer

    public init(controller: HeroTrailerController) {
        self.player = controller.player
    }

    public func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.isUserInteractionEnabled = false
        return view
    }

    public func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    /// A `UIView` whose backing layer is an `AVPlayerLayer`, so the video always
    /// fills the view without a manual frame-sync.
    public final class PlayerSurfaceView: UIView {
        public override static var layerClass: AnyClass { AVPlayerLayer.self }
        public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif
#endif
