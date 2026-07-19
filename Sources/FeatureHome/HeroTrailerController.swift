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

/// A fast hero-trailer source already resolved to a directly playable URL.
/// Home intentionally accepts only local/server-resolved sources here — never
/// a YouTube id that would require the slow/heavy on-device extraction path.
public struct HeroTrailerSource: Sendable, Equatable {
    public let ownerItemID: String
    public let trailerItemID: String
    public let url: URL
    public let duration: TimeInterval

    public init(
        ownerItemID: String,
        trailerItemID: String,
        url: URL,
        duration: TimeInterval
    ) {
        self.ownerItemID = ownerItemID
        self.trailerItemID = trailerItemID
        self.url = url
        self.duration = duration
    }
}

public typealias HeroTrailerResolving = @Sendable (MediaItem) async -> HeroTrailerSource?

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
    public private(set) var isReady = false
    /// The resolved trailer duration in seconds once known (`0` until ready).
    /// Drives the hero's dwell length so the progress bar spans the full trailer.
    public private(set) var duration: TimeInterval = 0
    /// The underlying player, exposed only so a ``HeroTrailerVideoLayer`` can
    /// attach an `AVPlayerLayer`. Engine-agnostic callers must not depend on it.
    public let player = AVPlayer()

    /// Fired on the main actor when the current trailer plays through to its end,
    /// so the hero can advance to the next item. Reset per load.
    private var endHandlerOwnerID: String?
    private var endHandler: (@MainActor () -> Void)?

    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var hasStartedPlayback = false
    private var autoplayWhenReady = false
    private var requestedPaused = false
    #if canImport(UIKit)
    @ObservationIgnored fileprivate let surfaceView = HeroTrailerPlayerSurfaceView()
    /// Only this logical surface may attach the physical player view. Explicit
    /// ownership prevents a stale disappearing hierarchy from stealing it back.
    public private(set) var surfaceOwnerID: String?
    #endif

    public init() {
        // Never let the trailer claim the Now-Playing transport or interrupt
        // music; it's ambient. Muting is applied per play() call.
        player.actionAtItemEnd = .pause
        #if canImport(UIKit)
        surfaceView.playerLayer.player = player
        #endif
    }

    /// Reads the source's actual AVFoundation duration before the hero timeline
    /// starts. Using the real stream duration keeps the wall-clock gauge and
    /// end-of-item advance on the same clock.
    public static func resolvedDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Whether this controller is already presenting `itemID` (so a hero→detail
    /// hand-off for the same title can keep playing rather than reload).
    public func isShowing(_ itemID: String) -> Bool {
        currentItemID == itemID && currentItemID != nil
    }

    public func claimSurface(ownerID: String) {
        #if canImport(UIKit)
        surfaceOwnerID = ownerID
        #endif
    }

    /// Installs the current frontmost surface's end handler. Ownership prevents
    /// a hidden Home carousel from clearing/replacing the detail page's handler.
    public func setEndHandler(
        ownerID: String,
        _ handler: @escaping @MainActor () -> Void
    ) {
        endHandlerOwnerID = ownerID
        endHandler = handler
    }

    public func clearEndHandler(ownerID: String) {
        guard endHandlerOwnerID == ownerID else { return }
        endHandlerOwnerID = nil
        endHandler = nil
    }

    /// Loads and plays `resolvedURL` as the trailer for `itemID`. No-op (keeps
    /// playing) if the same item is already showing. `muted` follows the profile's
    /// trailer-audio preference.
    public func play(itemID: String, resolvedURL: URL, muted: Bool) {
        prepare(itemID: itemID, resolvedURL: resolvedURL, muted: muted)
        autoplayWhenReady = true
        beginPlaybackIfReady()
    }

    /// Queues and preloads a trailer without starting it. Home uses this to make
    /// the item ready behind the still image, then starts one exact 3s+duration
    /// timeline only after readiness is known.
    public func prepare(itemID: String, resolvedURL: URL, muted: Bool) {
        if currentItemID == itemID, player.currentItem != nil {
            player.isMuted = muted
            return
        }

        stopPlayback(resetItem: false)
        activateSession()

        let item = AVPlayerItem(url: resolvedURL)
        player.isMuted = muted
        hasStartedPlayback = false
        autoplayWhenReady = false
        requestedPaused = false
        isReady = false
        duration = 0
        observeEnd(of: item)
        observeStatus(of: item)
        player.replaceCurrentItem(with: item)

        currentItemID = itemID
        PlozzLog.app.info("Hero trailer: queued item=\(itemID) muted=\(muted) url=\(PlozzLog.redact(url: resolvedURL))")
    }

    /// Starts a previously prepared item (or arms it to start when ready).
    public func startPrepared() {
        autoplayWhenReady = true
        beginPlaybackIfReady()
    }

    /// Applies a live mute change (e.g. the user flips the muted toggle) without
    /// reloading.
    public func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    /// Freezes/resumes the ambient trailer in lockstep with the hero's
    /// auto-advance pause so the wall-clock progress gauge and picture never
    /// drift apart during remote interaction or recede.
    public func setPaused(_ paused: Bool) {
        requestedPaused = paused
        guard currentItemID != nil else { return }
        if paused {
            player.pause()
        } else if hasStartedPlayback {
            player.play()
        }
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
            isReady = false
            currentItemID = nil
            duration = 0
        }
    }

    private func beginPlaybackIfReady() {
        guard autoplayWhenReady, isReady, !requestedPaused, !hasStartedPlayback else { return }
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
                self.endHandler?()
            }
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    self.isReady = true
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
fileprivate final class HeroTrailerPlayerSurfaceView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }
}

/// Hosts the controller's one physical AVPlayerLayer surface. Owner tokens make
/// reparenting deterministic across overlapping navigation hierarchies.
public struct HeroTrailerVideoLayer: UIViewRepresentable {
    private let controller: HeroTrailerController
    private let ownerID: String

    public init(controller: HeroTrailerController, ownerID: String) {
        self.controller = controller
        self.ownerID = ownerID
    }

    public func makeUIView(context: Context) -> HostView {
        let host = HostView()
        attach(to: host)
        return host
    }

    public func updateUIView(_ uiView: HostView, context: Context) {
        attach(to: uiView)
    }

    private func attach(to host: HostView) {
        guard controller.surfaceOwnerID == ownerID else { return }
        let surface = controller.surfaceView
        guard surface.superview !== host else { return }
        surface.removeFromSuperview()
        host.addSubview(surface)
        surface.frame = host.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    public final class HostView: UIView {
        public override func layoutSubviews() {
            super.layoutSubviews()
            subviews.forEach { $0.frame = bounds }
        }
    }
}
#endif
#endif
