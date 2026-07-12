#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import CoreNetworking
import Foundation
import Observation

/// Plays a detail page's theme without publishing Now Playing information or
/// claiming remote commands from video and full music playback.
@MainActor
@Observable
public final class ThemeMusicController {
    public private(set) var isPlaying = false
    public private(set) var currentPlaybackID: String?
    public private(set) var isBlocked = false

    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var fadeTimeObserver: Any?
    private var fadeTarget: Float = 0
    private var hasFadedIn = false
    private var hasStartedPlayback = false
    private let fadeInDuration: Double = 5

    public init() {}

    public func setBlocked(_ blocked: Bool) {
        isBlocked = blocked
        if blocked {
            stop()
        }
    }

    public func play(
        _ theme: ThemeMusic,
        resolvedURL: URL,
        playbackID: String,
        settings: ThemeMusicSettings
    ) {
        guard settings.shouldPlay, !isBlocked else {
            stop(ifPlaying: playbackID)
            return
        }

        if isPlaying, currentPlaybackID == playbackID {
            fadeTarget = settings.volume.gain
            if hasFadedIn {
                player.volume = fadeTarget
            }
            return
        }

        stopPlayback(resetItem: false)
        activateSession()

        let item = AVPlayerItem(url: resolvedURL)
        player.volume = 0
        fadeTarget = settings.volume.gain
        hasFadedIn = false
        hasStartedPlayback = false
        observeEnd(of: item)
        observeStatus(of: item, themeURL: resolvedURL)
        player.replaceCurrentItem(with: item)

        isPlaying = true
        currentPlaybackID = playbackID
        PlozzLog.app.info(
            "Theme music: queued item=\(theme.itemID) volume=\(settings.volume.gain) url=\(PlozzLog.redact(url: resolvedURL))"
        )
    }

    public func stop() {
        guard isPlaying || currentPlaybackID != nil else { return }
        stopPlayback(resetItem: true)
        PlozzLog.app.info("Theme music: stopped")
    }

    public func stop(ifPlaying playbackID: String) {
        guard currentPlaybackID == playbackID else { return }
        stop()
    }

    private func stopPlayback(resetItem: Bool) {
        removeFadeObserver()
        hasFadedIn = false
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
            currentPlaybackID = nil
        }
    }

    private func beginPlaybackIfReady() {
        guard !hasStartedPlayback, !isBlocked else { return }
        hasStartedPlayback = true
        player.seek(to: .zero)
        installFadeObserver()
        player.play()
    }

    private func installFadeObserver() {
        removeFadeObserver()
        guard fadeTarget > 0, fadeInDuration > 0 else {
            player.volume = fadeTarget
            hasFadedIn = true
            return
        }

        player.volume = 0
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        fadeTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.hasFadedIn else { return }
                let elapsed = time.seconds
                guard elapsed.isFinite else { return }
                if elapsed >= self.fadeInDuration {
                    self.player.volume = self.fadeTarget
                    self.hasFadedIn = true
                    self.removeFadeObserver()
                } else {
                    self.player.volume = self.fadeTarget * Float(
                        max(0, elapsed / self.fadeInDuration)
                    )
                }
            }
        }
    }

    private func removeFadeObserver() {
        guard let fadeTimeObserver else { return }
        player.removeTimeObserver(fadeTimeObserver)
        self.fadeTimeObserver = nil
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
                self?.handleItemDidEnd()
            }
        }
    }

    private func handleItemDidEnd() {
        stop()
    }

    private func observeStatus(of item: AVPlayerItem, themeURL: URL) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    PlozzLog.app.info(
                        "Theme music: ready url=\(PlozzLog.redact(url: themeURL))"
                    )
                    self.beginPlaybackIfReady()
                case .failed:
                    let detail = item.error.map(String.init(describing:)) ?? "unknown"
                    PlozzLog.app.error(
                        "Theme music: failed url=\(PlozzLog.redact(url: themeURL)) error=\(detail)"
                    )
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
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            PlozzLog.app.error(
                "Theme music: audio session activation failed error=\(String(describing: error))"
            )
        }
        #endif
    }
}
#endif
