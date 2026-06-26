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
    /// Pulls a fresh engine-health snapshot for non-AVFoundation engines (mpv).
    /// `nil` for engines that don't report stats (the native engine surfaces drops
    /// through `AVPlayerItem.accessLog()` instead).
    private var engineStatsProvider: (@MainActor () -> PlaybackEngineStats?)?
    /// Last measured main-thread scheduling slip (ms), applied to each snapshot so
    /// the overlay can flag a blocked main actor.
    private var lastHitchMillis: Double?
    /// Immutable per-stream facts (codec/HDR/fps/mode/container/device) merged
    /// into every dynamic sample.
    private var staticDiagnostics = PlaybackDiagnostics()
    private var timerTask: Task<Void, Never>?

    public init() {}

    /// Begins sampling `player`. Idempotent — restarts cleanly if called again.
    ///
    /// - Parameters:
    ///   - player: the active player to sample.
    ///   - mode: how the server delivers the stream (direct play / remux /
    ///     transcode), shown verbatim in the overlay's Source row.
    ///   - metadata: provider source facts (codec/HDR/channels/…). These are the
    ///     authoritative baseline; the transcoded asset itself exposes little,
    ///     so this is what makes the overlay match a direct-play client.
    ///   - engineName: the engine decoding the stream (e.g. `AVPlayer`, `VLCKit`),
    ///     shown in the overlay so the user can see which engine is active.
    ///   - engineStats: an optional pull for the active engine's live runtime
    ///     health (decode path, frame drops, rendered fps). Supplied for engines
    ///     that conform to `PlaybackStatsProviding` (mpv); `nil` for AVPlayer-based
    ///     playback, which reports drops through its own access log.
    ///
    /// `player` is optional: a non-AVFoundation engine (VLCKit/mpv) has no
    /// `AVPlayer`, so the live per-tick AVFoundation metrics (observed bitrate,
    /// dropped frames, presentation size) are skipped — but if `engineStats` is
    /// supplied, the engine's own decode/drop/fps health is sampled on the same
    /// cadence so the overlay still shows whether the device is keeping up. The
    /// authoritative baseline from `metadata` — container, codecs, HDR, mode, and
    /// the engine name — is always published so the overlay works on every engine.
    public func start(
        player: AVPlayer?,
        mode: PlaybackDiagnostics.PlaybackMode,
        metadata: MediaSourceMetadata? = nil,
        engineName: String? = nil,
        engineStats: (@MainActor () -> PlaybackEngineStats?)? = nil
    ) {
        stop()
        self.player = player
        self.engineStatsProvider = engineStats
        self.lastHitchMillis = nil
        var base = PlaybackDiagnostics.base(from: metadata, mode: mode)
        base.engineName = engineName
        Self.fillDeviceInfo(into: &base)
        staticDiagnostics = base
        latest = staticDiagnostics

        // Run the live timer when there's anything to sample each tick: an
        // AVPlayer (AVFoundation metrics), an engine-stats pull (mpv health), or
        // both. With neither, the metadata-only baseline above is the whole
        // snapshot and no timer is needed.
        guard player != nil || engineStats != nil else { return }

        if player != nil {
            Task { await loadStaticInfo() }
        }

        timerTask = Task { [weak self] in
            // Measure how late each tick lands vs its 1s schedule — a blocked main
            // actor delays the post-sleep resume, which is our coarse hang hint.
            while !Task.isCancelled {
                self?.tick()
                let scheduledAt = Date()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                let slip = Date().timeIntervalSince(scheduledAt) - 1.0
                self?.lastHitchMillis = max(0, slip * 1000)
            }
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        player = nil
        engineStatsProvider = nil
        lastHitchMillis = nil
    }

    // MARK: Per-tick sampling

    /// One sampling pass: AVFoundation metrics (when there's an `AVPlayer`),
    /// engine-reported health (when an engine-stats pull is wired), and the
    /// main-thread hitch hint — merged onto the static baseline.
    private func tick() {
        var diagnostics = staticDiagnostics

        if let item = player?.currentItem {
            mergeAVPlayerMetrics(into: &diagnostics, item: item)
        }
        if let stats = engineStatsProvider?() {
            diagnostics.apply(engineStats: stats)
        }
        diagnostics.mainThreadHitchMillis = lastHitchMillis
        latest = diagnostics
    }

    private func mergeAVPlayerMetrics(into diagnostics: inout PlaybackDiagnostics, item: AVPlayerItem) {
        // Source metadata resolution wins; only fall back to the rendered
        // presentation size when the provider didn't report dimensions.
        if diagnostics.resolution == nil {
            let size = item.presentationSize
            if size.width > 0, size.height > 0 {
                diagnostics.resolution = .init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
            }
        }

        if let event = item.accessLog()?.events.last {
            if event.indicatedBitrate > 0 { diagnostics.indicatedBitrate = event.indicatedBitrate }
            if event.observedBitrate > 0 { diagnostics.observedBitrate = event.observedBitrate }
            if event.numberOfDroppedVideoFrames >= 0 {
                diagnostics.droppedVideoFrames = event.numberOfDroppedVideoFrames
            }
        }

        diagnostics.bufferedSecondsAhead = bufferedSecondsAhead(in: item)
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

        if info.container == nil, let urlAsset = asset as? AVURLAsset {
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
                // Provider source facts are authoritative; only fill from the
                // (possibly transcoded) asset when the provider gave us nothing.
                if info.videoCodec == nil {
                    info.videoCodec = PlaybackDiagnostics.friendlyCodecName(codec)
                }
                if info.hdr == .unknown {
                    info.hdr = PlaybackDiagnostics.classifyHDR(videoCodec: codec, transferFunction: transfer)
                }
            }
            if info.frameRate == nil, let fps = try? await videoTrack.load(.nominalFrameRate), fps > 0 {
                info.frameRate = Double(fps)
            }
            if info.resolution == nil,
               let size = try? await videoTrack.load(.naturalSize), size.width > 0, size.height > 0 {
                info.resolution = .init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
            }
        }

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let descriptions = try? await audioTrack.load(.formatDescriptions), let desc = descriptions.first {
            // Provider source facts are authoritative; only fill from the played
            // (possibly transcoded) asset when the provider gave us nothing, so
            // the overlay still surfaces the active audio format / channel layout.
            if info.audioCodec == nil {
                let codec = Self.fourCCString(CMFormatDescriptionGetMediaSubType(desc))
                info.audioCodec = PlaybackDiagnostics.friendlyCodecName(codec)
            }
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                if info.audioChannels == nil, asbd.mChannelsPerFrame > 0 {
                    info.audioChannels = Int(asbd.mChannelsPerFrame)
                }
                if info.audioSampleRate == nil, asbd.mSampleRate > 0 {
                    info.audioSampleRate = Int(asbd.mSampleRate.rounded())
                }
            }
        }

        staticDiagnostics = info
    }

    // MARK: Device / disk facts (queried once)

    /// Populates the device model, physical memory, and free/total disk space.
    private static func fillDeviceInfo(into diagnostics: inout PlaybackDiagnostics) {
        diagnostics.deviceModel = deviceModelName()
        diagnostics.deviceMemoryBytes = Int64(ProcessInfo.processInfo.physicalMemory)

        if let url = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey
            ])
            if let free = values?.volumeAvailableCapacity {
                diagnostics.freeDiskBytes = Int64(free)
            }
            if let total = values?.volumeTotalCapacity {
                diagnostics.totalDiskBytes = Int64(total)
            }
        }
    }

    /// Friendly Apple TV model name from the hardware identifier (e.g.
    /// `AppleTV14,1` → `Apple TV 4K (3rd gen)`).
    private static func deviceModelName() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        switch identifier {
        case "AppleTV5,3": return "Apple TV HD"
        case "AppleTV6,2": return "Apple TV 4K"
        case "AppleTV11,1": return "Apple TV 4K (2nd gen)"
        case "AppleTV14,1": return "Apple TV 4K (3rd gen)"
        default:
            // Simulators report e.g. "arm64"/"x86_64"; show something sensible.
            return identifier.isEmpty || identifier.contains("64") ? "Apple TV" : identifier
        }
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
