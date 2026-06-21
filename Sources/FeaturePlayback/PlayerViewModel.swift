#if canImport(AVFoundation)
import Foundation
import AVFoundation
import Observation
import CoreModels
import CoreNetworking

/// Owns the `AVPlayer` for a single playback session.
///
/// Responsibilities:
///  * resolve a `PlaybackRequest` via the provider;
///  * seek to the saved resume position on start;
///  * report progress to the server periodically + on pause/stop so resume
///    points stay in sync (Phase 1 requirement);
///  * surface a graceful error state instead of a blank screen.
@MainActor
@Observable
public final class PlayerViewModel {
    public enum Phase: Equatable {
        case loading
        case ready
        case failed(AppError)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var player: AVPlayer?

    private let provider: any MediaProvider
    private let itemID: String
    private let captionSettings: CaptionSettings
    private var request: PlaybackRequest?
    private var timeObserver: Any?
    private let reportInterval: TimeInterval = 10
    private var lastReportedSecond: Int = -1

    public init(
        provider: any MediaProvider,
        itemID: String,
        captionSettings: CaptionSettings = .default
    ) {
        self.provider = provider
        self.itemID = itemID
        self.captionSettings = captionSettings
    }

    /// Loads stream info, configures the player, and seeks to resume.
    public func load() async {
        phase = .loading
        do {
            let request = try await provider.playbackInfo(for: itemID)
            self.request = request

            let asset = AVURLAsset(url: request.streamURL)
            let item = AVPlayerItem(asset: asset)
            // Apply in-app caption styling overrides if the user set any.
            item.textStyleRules = captionSettings.textStyleRules()

            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true
            self.player = player

            if request.startPosition > 1 {
                let time = CMTime(seconds: request.startPosition, preferredTimescale: 600)
                await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }

            installTimeObserver(on: player)
            phase = .ready
            player.play()
            await report(event: .start, isPaused: false)
        } catch let error as AppError {
            phase = .failed(error)
        } catch {
            phase = .failed(.unknown(""))
        }
    }

    private func installTimeObserver(on player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = Int(time.seconds)
            guard seconds != self.lastReportedSecond, seconds % Int(self.reportInterval) == 0 else { return }
            self.lastReportedSecond = seconds
            Task { await self.report(event: .progress, isPaused: false) }
        }
    }

    /// Reports the current position. Best-effort: a failed report must never
    /// interrupt playback, so errors are swallowed (and never logged with data).
    private func report(event: PlaybackEvent, isPaused: Bool) async {
        guard let player, let request else { return }
        let progress = PlaybackProgress(
            itemID: itemID,
            playSessionID: request.playSessionID,
            positionSeconds: player.currentTime().seconds,
            isPaused: isPaused
        )
        do {
            try await provider.reportPlayback(progress, event: event)
        } catch {
            PlizzLog.playback.debug("Progress report failed (non-fatal)")
        }
    }

    public func setPaused(_ paused: Bool) {
        guard let player else { return }
        if paused { player.pause() } else { player.play() }
        Task { await report(event: paused ? .pause : .unpause, isPaused: paused) }
    }

    /// Call when leaving playback: report a final stop so the server records the
    /// resume point, then tear the player down.
    public func stop() async {
        await report(event: .stop, isPaused: true)
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    public var availableSubtitleTracks: [MediaTrack] { request?.subtitleTracks ?? [] }
    public var availableAudioTracks: [MediaTrack] { request?.audioTracks ?? [] }
}

#endif
