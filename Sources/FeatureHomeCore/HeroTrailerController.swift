#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import CoreModels
import CoreNetworking
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
import SwiftUI
#endif

/// A fast, shared hero-trailer source already resolved to a directly playable URL.
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

public enum HeroTrailerSurfaceRole: Sendable, Equatable {
    case home
    case detail
}

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
    public private(set) var isPaused = false
    /// The live (session) mute state of the trailer. Initialized from the active
    /// surface's mute *default* when a trailer starts, but the in-hero mute button
    /// flips THIS (a transient session override) — it never rewrites the saved
    /// default, so muting/unmuting a playing trailer doesn't change the setting.
    public private(set) var isMuted = true
    public private(set) var pauseStartedAt: Date?
    public private(set) var activeSurfaceRole: HeroTrailerSurfaceRole?
    /// The resolved trailer duration in seconds once known (`0` until ready).
    /// Drives the hero's dwell length so the progress bar spans the full trailer.
    public private(set) var duration: TimeInterval = 0
    /// One frozen frame captured immediately before Home pushes detail. It masks
    /// the few-frame gap while the shared player moves between AVPlayerLayers.
    /// Bounded to exactly one image and replaced on every handoff.
    public private(set) var handoffImage: UIImage?

    /// The underlying player, exposed only so a ``HeroTrailerVideoLayer`` can
    /// attach an `AVPlayerLayer`. Engine-agnostic callers must not depend on it.
    public let player = AVPlayer()
    #if canImport(UIKit)
    /// Two persistent display layers fed by the same AVPlayer. Detail's layer is
    /// pre-rendered invisibly on Home; Home's remains warm under the pop.
    @ObservationIgnored fileprivate let homeSurfaceView = HeroTrailerPlayerSurfaceView()
    @ObservationIgnored fileprivate let detailSurfaceView = HeroTrailerPlayerSurfaceView()
    #endif

    /// Fired on the main actor when the current trailer plays through to its end,
    /// so the hero can advance to the next item. Reset per load.
    private var endHandlerOwnerID: String?
    private var endHandler: (@MainActor () -> Void)?

    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var hasStartedPlayback = false
    private var autoplayWhenReady = false
    private var requestedPaused = false
    private var captionSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private let imageContext = CIContext(options: nil)

    public init() {
        // Never let the trailer claim the Now-Playing transport or interrupt
        // music; it's ambient. Muting is applied per play() call.
        player.actionAtItemEnd = .pause
        player.appliesMediaSelectionCriteriaAutomatically = false
        #if canImport(UIKit)
        homeSurfaceView.playerLayer.player = player
        detailSurfaceView.playerLayer.player = player
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

    /// Marks the frontmost renderer. Touch surfaces use this to keep a Home →
    /// detail handoff alive while still stopping playback when Home truly leaves.
    public func claimSurface(_ role: HeroTrailerSurfaceRole, itemID: String) {
        guard currentItemID == nil || currentItemID == itemID else { return }
        activeSurfaceRole = role
    }

    public func isClaimed(by role: HeroTrailerSurfaceRole, itemID: String) -> Bool {
        activeSurfaceRole == role && currentItemID == itemID
    }

    public func releaseSurface(_ role: HeroTrailerSurfaceRole) {
        guard activeSurfaceRole == role else { return }
        activeSurfaceRole = nil
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
            isMuted = muted
            return
        }

        stopPlayback(resetItem: false)
        activateSession()

        let item = AVPlayerItem(url: resolvedURL)
        let output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
        )
        item.add(output)
        videoOutput = output
        player.isMuted = muted
        isMuted = muted
        hasStartedPlayback = false
        autoplayWhenReady = false
        requestedPaused = isPaused
        isReady = false
        duration = 0
        observeEnd(of: item)
        observeStatus(of: item)
        player.replaceCurrentItem(with: item)
        disableCaptions(on: item)

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
        isMuted = muted
    }

    /// Flip the live (session) mute — what the in-hero mute button calls. Transient:
    /// it does NOT touch the persisted mute default.
    public func toggleMuted() {
        setMuted(!isMuted)
    }

    /// Captures the currently displayed video frame for a seamless layer handoff.
    /// Failure is harmless (the detail layer falls back to its normal background).
    public func captureHandoffFrame() async {
        let itemTime = player.currentTime()
        // Fast path: use the live decoded pixel buffer when available.
        if let videoOutput,
           let pixelBuffer = videoOutput.copyPixelBuffer(
               forItemTime: itemTime,
               itemTimeForDisplay: nil
           ) {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImage = imageContext.createCGImage(image, from: image.extent) {
                handoffImage = UIImage(cgImage: cgImage)
                return
            }
        }

        // Reliable fallback: generate the exact current frame from the already
        // loaded asset before pushing detail. Navigation waits for this one frame,
        // eliminating the race where a missing live-output snapshot exposed art.
        guard let asset = player.currentItem?.asset else {
            handoffImage = nil
            return
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(
            seconds: 0.05,
            preferredTimescale: 600
        )
        generator.requestedTimeToleranceAfter = CMTime(
            seconds: 0.05,
            preferredTimescale: 600
        )
        do {
            let generated = try await generator.image(at: itemTime)
            handoffImage = UIImage(cgImage: generated.image)
        } catch {
            handoffImage = nil
        }
    }

    /// Freezes/resumes the ambient trailer in lockstep with the hero's
    /// auto-advance pause so the wall-clock progress gauge and picture never
    /// drift apart during remote interaction or recede.
    public func setPaused(_ paused: Bool) {
        requestedPaused = paused
        if paused {
            if !isPaused { pauseStartedAt = .now }
            isPaused = true
        } else {
            isPaused = false
            pauseStartedAt = nil
        }
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
        captionSelectionTask?.cancel()
        captionSelectionTask = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        if resetItem {
            player.replaceCurrentItem(with: nil)
            videoOutput = nil
            handoffImage = nil
            isPlaying = false
            isReady = false
            isPaused = false
            pauseStartedAt = nil
            currentItemID = nil
            activeSurfaceRole = nil
            duration = 0
        }
    }

    private func disableCaptions(on item: AVPlayerItem) {
        captionSelectionTask = Task { @MainActor [weak self, weak item] in
            guard let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(
                    for: .legible
                  ),
                  !Task.isCancelled,
                  self?.player.currentItem === item else {
                return
            }
            item.select(nil, in: group)
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

/// Reparents one of the controller's two persistent AVPlayerLayer surfaces into
/// this SwiftUI host. The layer itself survives navigation hierarchy changes.
public struct HeroTrailerVideoLayer: UIViewRepresentable {
    private let controller: HeroTrailerController
    private let role: HeroTrailerSurfaceRole

    public init(
        controller: HeroTrailerController,
        role: HeroTrailerSurfaceRole
    ) {
        self.controller = controller
        self.role = role
    }

    public func makeUIView(context: Context) -> HostView {
        let host = HostView()
        attach(to: host)
        return host
    }

    public func updateUIView(_ uiView: HostView, context: Context) {
        attach(to: uiView)
    }

    private var surface: HeroTrailerPlayerSurfaceView {
        switch role {
        case .home: controller.homeSurfaceView
        case .detail: controller.detailSurfaceView
        }
    }

    private func attach(to host: HostView) {
        let surface = surface
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
