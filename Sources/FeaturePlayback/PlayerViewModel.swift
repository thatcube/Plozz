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
                await seekWhenReady(player: player, to: request.startPosition)
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

    /// Seeks to `seconds`, clamped into the stream's seekable range. Tolerances
    /// are non-zero so far seeks resolve to the nearest keyframe instead of
    /// stalling on an exact-frame seek (which can fail on transcoded HLS).
    public func seek(to seconds: TimeInterval) async {
        guard let player else { return }
        await seek(player: player, to: seconds)
    }

    /// Waits (briefly) for the player item to become ready before seeking. A
    /// resume seek issued before the asset is ready — common for far positions —
    /// is silently dropped by AVPlayer, leaving playback at 0.
    private func seekWhenReady(player: AVPlayer, to seconds: TimeInterval) async {
        guard let item = player.currentItem else { return }
        let deadline = Date().addingTimeInterval(5)
        while item.status != .readyToPlay, Date() < deadline {
            if item.status == .failed { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await seek(player: player, to: seconds)
    }

    private func seek(player: AVPlayer, to seconds: TimeInterval) async {
        let target = clampToSeekableRange(seconds, item: player.currentItem)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        // Allow a small tolerance: exact (.zero) seeks can stall or fail on
        // transcoded HLS, which is exactly the far-seek failure we're fixing.
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        await player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    /// Clamps a target time into the item's seekable range when one is known, so
    /// a seek past the currently-available range doesn't error out.
    private func clampToSeekableRange(_ seconds: TimeInterval, item: AVPlayerItem?) -> TimeInterval {
        guard let ranges = item?.seekableTimeRanges, !ranges.isEmpty else { return max(0, seconds) }
        var lower = TimeInterval.greatestFiniteMagnitude
        var upper = 0.0
        for value in ranges {
            let range = value.timeRangeValue
            lower = min(lower, range.start.seconds)
            upper = max(upper, (range.start + range.duration).seconds)
        }
        guard upper > 0 else { return max(0, seconds) }
        return min(max(seconds, lower), upper)
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
            PlozzLog.playback.debug("Progress report failed (non-fatal)")
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

    /// Whether the active stream is being transcoded by the server (vs direct
    /// play). Read by the playback diagnostics overlay.
    public var isTranscoding: Bool { request?.isTranscoding ?? false }
}

#endif
