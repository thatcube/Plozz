#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreMedia
import Observation
import CoreModels

/// Samples live playback metrics off the active `AVPlayer`/`AVPlayerItem` and
/// publishes a `PlaybackDiagnostics` snapshot for the overlay.
///
/// Design notes:
///  * **Never blocks the main actor.** Static, one-shot track info (codec, HDR,
///    frame rate, natural size) is read with the async `load(_:)` APIs, which
///    suspend rather than block. Per-tick reads (`presentationSize`,
///    `accessLog()`, `loadedTimeRanges`) are cheap synchronous property
///    accesses that don't stall playback.
///  * Dynamic values are re-sampled ~1s; immutable track facts are loaded once
///    and cached, so the timer does minimal work.
///  * The pure classification/formatting lives in `PlaybackDiagnostics`
///    (CoreModels) so it can be unit-tested without a player.
@MainActor
@Observable
public final class PlaybackDiagnosticsSampler {
    /// The most recent snapshot, or `nil` before the first sample lands.
    public private(set) var latest: PlaybackDiagnostics?

    private weak var player: AVPlayer?
    /// Immutable per-stream facts (codec/HDR/fps/mode/container) merged into
    /// every dynamic sample.
    private var staticDiagnostics = PlaybackDiagnostics()
    private var timerTask: Task<Void, Never>?

    public init() {}

    /// Begins sampling `player`. Idempotent — restarts cleanly if called again.
    public func start(player: AVPlayer, isTranscoding: Bool) {
        stop()
        self.player = player
        staticDiagnostics = PlaybackDiagnostics(mode: isTranscoding ? .transcode : .directPlay)
        latest = staticDiagnostics

        Task { await loadStaticInfo() }

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleDynamic()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        player = nil
    }

    // MARK: Dynamic (per-tick) sampling

    private func sampleDynamic() {
        guard let item = player?.currentItem else { return }
        var diagnostics = staticDiagnostics

        let size = item.presentationSize
        if size.width > 0, size.height > 0 {
            diagnostics.resolution = .init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        }

        if let event = item.accessLog()?.events.last {
            if event.indicatedBitrate > 0 { diagnostics.indicatedBitrate = event.indicatedBitrate }
            if event.observedBitrate > 0 { diagnostics.observedBitrate = event.observedBitrate }
            if event.numberOfDroppedVideoFrames >= 0 {
                diagnostics.droppedVideoFrames = event.numberOfDroppedVideoFrames
            }
        }

        diagnostics.bufferedSecondsAhead = bufferedSecondsAhead(in: item)
        latest = diagnostics
    }

    /// Seconds of contiguous media buffered ahead of the current position.
    private func bufferedSecondsAhead(in item: AVPlayerItem) -> Double? {
        let current = item.currentTime().seconds
        guard current.isFinite else { return nil }
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            guard start.isFinite, end.isFinite else { continue }
            if current >= start - 0.5, current <= end {
                return max(0, end - current)
            }
        }
        return nil
    }

    // MARK: Static (one-shot) track info

    private func loadStaticInfo() async {
        guard let asset = player?.currentItem?.asset else { return }
        var info = staticDiagnostics

        if let urlAsset = asset as? AVURLAsset {
            let ext = urlAsset.url.pathExtension
            if !ext.isEmpty { info.container = ext.uppercased() }
        }

        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            if let descriptions = try? await videoTrack.load(.formatDescriptions), let desc = descriptions.first {
                let codec = Self.fourCCString(CMFormatDescriptionGetMediaSubType(desc))
                let transfer = CMFormatDescriptionGetExtension(
                    desc,
                    extensionKey: kCMFormatDescriptionExtension_TransferFunction
                ) as? String
                info.videoCodec = PlaybackDiagnostics.friendlyCodecName(codec)
                info.hdr = PlaybackDiagnostics.classifyHDR(videoCodec: codec, transferFunction: transfer)
            }
            if let fps = try? await videoTrack.load(.nominalFrameRate), fps > 0 {
                info.frameRate = Double(fps)
            }
            if let size = try? await videoTrack.load(.naturalSize), size.width > 0, size.height > 0,
               info.resolution == nil {
                info.resolution = .init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
            }
        }

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let descriptions = try? await audioTrack.load(.formatDescriptions), let desc = descriptions.first {
            let codec = Self.fourCCString(CMFormatDescriptionGetMediaSubType(desc))
            info.audioCodec = PlaybackDiagnostics.friendlyCodecName(codec)
        }

        staticDiagnostics = info
    }

    /// Renders a CoreMedia FourCC code as its ASCII tag (e.g. `hvc1`).
    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let scalars = bytes.map { Character(UnicodeScalar($0)) }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}
#endif
