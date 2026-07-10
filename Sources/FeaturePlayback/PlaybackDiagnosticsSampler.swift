#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreMedia
import Observation
import CoreModels
import os

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
    /// Immutable per-stream facts (codec/HDR/fps/mode/container/device) merged
    /// into every dynamic sample.
    private var staticDiagnostics = PlaybackDiagnostics()
    /// Live engine telemetry source (dropped frames / FPS / bitrate). Used to fill
    /// the per-tick metrics on engines with no `AVPlayer` access log (Plozzigen).
    private var engineTelemetry: (@MainActor () -> EngineLiveTelemetry?)?
    /// Engine-probed source facts (real range/audio/dimensions). Fills the
    /// diagnostics for sources with no provider metadata (SMB) where the engine's
    /// own demux is the only source of truth.
    private var probedFacts: (@MainActor () -> EngineProbedSourceFacts?)?
    private var timerTask: Task<Void, Never>?

    /// Last AVPlayer access-log stall count we logged, so a `remux-stall:` marker
    /// is emitted once per NEW stall (the direct stutter signal correlated, in the
    /// coordinator's --console capture, with the `remux-av:`/`remux-tput:` lines).
    private var lastLoggedStallCount = 0
    private static let playbackLog = Logger(subsystem: "com.thatcube.Plozz", category: "Playback")

    /// `REMUX_STDOUT=1` mirrors the `remux-stall:` marker to stdout (prefixed
    /// `PLZREMUX `) so `devicectl --console` captures it — os_log alone isn't
    /// readable off a network-paired Apple TV on this toolchain.
    private static let mirrorsStandardOut: Bool =
        ProcessInfo.processInfo.environment["REMUX_STDOUT"] == "1"

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
    ///
    /// `player` is optional: a non-AVFoundation engine (Plozzigen) has no
    /// `AVPlayer`, so the live per-tick metrics (observed bitrate, dropped frames,
    /// presentation size) are skipped, but the authoritative baseline from
    /// `metadata` — container, codecs, HDR, mode, and the engine name — is still
    /// published so the overlay works on every engine.
    public func start(
        player: AVPlayer?,
        mode: PlaybackDiagnostics.PlaybackMode,
        metadata: MediaSourceMetadata? = nil,
        engineName: String? = nil,
        capabilities: MediaCapabilities = .detected(),
        sourceProvider: ProviderKind? = nil,
        serverName: String? = nil,
        sourceFileName: String? = nil,
        streamURL: URL? = nil,
        engineTelemetry: (@MainActor () -> EngineLiveTelemetry?)? = nil,
        probedFacts: (@MainActor () -> EngineProbedSourceFacts?)? = nil
    ) {
        stop()
        self.player = player
        self.engineTelemetry = engineTelemetry
        self.probedFacts = probedFacts
        self.lastLoggedStallCount = 0
        var base = PlaybackDiagnostics.base(
            from: metadata,
            mode: mode,
            capabilities: capabilities,
            sourceProvider: sourceProvider,
            serverName: serverName
        )
        base.engineName = engineName
        base.sourceFileName = sourceFileName
        base.streamTransport = PlaybackDiagnostics.streamTransportSummary(url: streamURL)
        Self.fillDeviceInfo(into: &base)
        staticDiagnostics = base
        latest = staticDiagnostics

        // Plozzigen exposes no AVFoundation item, but we still run the timer so
        // the system metrics (memory / thermal / live-instance counts) refresh
        // ~1s on *every* engine — that's what surfaces a leak on the HDR/DoVi
        // (Plozzigen) path, which otherwise published a single static snapshot.
        if player != nil {
            Task { await loadStaticInfo() }
        }

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleTick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
        player = nil
        engineTelemetry = nil
        probedFacts = nil
    }

    // MARK: Dynamic (per-tick) sampling

    /// Emits a `remux-stall:` os_log marker once per NEW AVPlayer stall recorded
    /// in the access log, with the live throughput context (observed vs indicated
    /// bitrate, buffered-ahead, position). A growing stall count alongside a low
    /// observed bitrate is the throughput-starvation fingerprint; stalls with
    /// healthy throughput point instead at a timeline-drift bug.
    private func logNewStalls(event: AVPlayerItemAccessLogEvent, item: AVPlayerItem) {
        let stalls = event.numberOfStalls
        guard stalls > lastLoggedStallCount else { return }
        lastLoggedStallCount = stalls
        let observedMbps = event.observedBitrate > 0 ? event.observedBitrate / 1_000_000 : -1
        let indicatedMbps = event.indicatedBitrate > 0 ? event.indicatedBitrate / 1_000_000 : -1
        let buffered = bufferedSecondsAhead(in: item) ?? -1
        let pos = item.currentTime().seconds
        let posValue = pos.isFinite ? pos : -1
        Self.playbackLog.error("""
            remux-stall: stalls=\(stalls, privacy: .public) \
            observed=\(observedMbps, format: .fixed(precision: 1), privacy: .public)Mbps \
            indicated=\(indicatedMbps, format: .fixed(precision: 1), privacy: .public)Mbps \
            buffered=\(buffered, format: .fixed(precision: 2), privacy: .public)s \
            pos=\(posValue, format: .fixed(precision: 1), privacy: .public)s
            """)
        if Self.mirrorsStandardOut {
            let line = String(format:
                "remux-stall: stalls=%d observed=%.1fMbps indicated=%.1fMbps buffered=%.2fs pos=%.1fs",
                stalls, observedMbps, indicatedMbps, buffered, posValue)
            try? FileHandle.standardOutput.write(contentsOf: Data(("PLZREMUX " + line + "\n").utf8))
        }
    }

    private func sampleTick() {
        var diagnostics = staticDiagnostics

        // Per-tick AVFoundation metrics (native engine only; Plozzigen has no item).
        if let item = player?.currentItem {
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
                logNewStalls(event: event, item: item)
            }

            diagnostics.bufferedSecondsAhead = bufferedSecondsAhead(in: item)

            // Timeline + seek window: the key seek diagnostic. A throttled server
            // HLS stream reports a small trailing seekable window; an app-owned
            // stream reports the whole duration as seekable.
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 { diagnostics.durationSeconds = duration }
            let position = item.currentTime().seconds
            if position.isFinite, position >= 0 { diagnostics.positionSeconds = position }
            if let seekable = item.seekableTimeRanges.last?.timeRangeValue {
                let start = seekable.start.seconds
                let end = (seekable.start + seekable.duration).seconds
                if start.isFinite { diagnostics.seekableStartSeconds = start }
                if end.isFinite { diagnostics.seekableEndSeconds = end }
            }

            diagnostics.playbackState = Self.playbackStateText(item: item, player: player)

            // Fall back to the live asset URL if the transport wasn't seeded at start.
            if diagnostics.streamTransport == nil, let urlAsset = item.asset as? AVURLAsset {
                diagnostics.streamTransport = PlaybackDiagnostics.streamTransportSummary(url: urlAsset.url)
            }
        }

        // Engines without an AVPlayer (Plozzigen) have no access log, so the
        // dropped-frames/FPS/bitrate fields stay blank above. Fill them from the
        // engine's own live telemetry; only overwrite where the access log didn't.
        if let t = engineTelemetry?() {
            if let drops = t.droppedFrameCount, diagnostics.droppedVideoFrames == nil {
                diagnostics.droppedVideoFrames = drops
            }
            if let fps = t.observedFps, diagnostics.observedFps == nil {
                diagnostics.observedFps = fps
            }
            if let bitrate = t.observedBitrate, diagnostics.observedBitrate == nil {
                diagnostics.observedBitrate = bitrate
            }
        }

        // Fill the authoritative stream facts from the engine's OWN probe when the
        // provider gave us none (SMB shares have no server metadata). Only fill
        // where the baseline is still empty/unknown, so real provider facts always
        // win — and we assert a range ONLY when the engine actually knows one
        // (better to show nothing than a defaulted "SDR").
        if let f = probedFacts?() {
            if diagnostics.hdr == .unknown, let r = f.range {
                diagnostics.hdr = Self.hdrFormat(for: r)
                if diagnostics.videoRangeType == nil {
                    diagnostics.videoRangeType = Self.rangeToken(for: r)
                }
            }
            if diagnostics.resolution == nil, let w = f.videoWidth, let h = f.videoHeight, w > 0, h > 0 {
                diagnostics.resolution = .init(width: w, height: h)
            }
            if diagnostics.audioCodec == nil, let codec = f.audioCodec {
                diagnostics.audioCodec = PlaybackDiagnostics.friendlyAudioName(
                    codec: codec, profile: f.audioIsAtmos ? "atmos" : nil
                )
            }
            if diagnostics.audioChannels == nil, let ch = f.audioChannels, ch > 0 {
                diagnostics.audioChannels = ch
            }
        }

        // System metrics refresh on every engine so a leak is visible on the
        // Plozzigen (HDR/DoVi) path too.
        Self.fillSystemMetrics(into: &diagnostics)
        latest = diagnostics
    }

    /// Live process memory, thermal pressure, and leak-counter snapshot. These
    /// distinguish a leak (memory / live counts climb, thermal flat) from
    /// thermal throttling (thermal rises toward critical, memory flat).
    private static func fillSystemMetrics(into diagnostics: inout PlaybackDiagnostics) {
        diagnostics.memoryFootprintBytes = PlaybackInstrumentation.memoryFootprintBytes()
        diagnostics.thermalState = currentThermalLevel()
        diagnostics.liveViewModels = PlaybackInstrumentation.count(.viewModel)
        diagnostics.liveNativeEngines = PlaybackInstrumentation.count(.nativeEngine)
    }

    private static func hdrFormat(for range: EngineProbedSourceFacts.DynamicRange) -> PlaybackDiagnostics.HDRFormat {
        switch range {
        case .sdr: return .sdr
        case .hlg: return .hlg
        case .hdr10, .hdr10Plus: return .hdr10
        case .dolbyVision: return .dolbyVision
        }
    }

    /// Provider-agnostic range token, matching the `videoRangeType` strings the
    /// rest of the pipeline uses (Jellyfin's vocabulary).
    private static func rangeToken(for range: EngineProbedSourceFacts.DynamicRange) -> String {
        switch range {
        case .sdr: return "SDR"
        case .hlg: return "HLG"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "DOVI"
        }
    }

    private static func currentThermalLevel() -> PlaybackDiagnostics.ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    /// Live player state, combining the item's load status with the player's
    /// time-control status so a black-screen failure or a buffering stall is
    /// visible in the overlay.
    private static func playbackStateText(item: AVPlayerItem, player: AVPlayer?) -> String {
        switch item.status {
        case .failed:
            if let error = item.error { return "Failed: \(error.localizedDescription)" }
            return "Failed"
        case .unknown:
            return "Loading"
        case .readyToPlay:
            let control: String?
            switch player?.timeControlStatus {
            case .playing: control = "Playing"
            case .paused: control = "Paused"
            case .waitingToPlayAtSpecifiedRate: control = "Waiting/Buffering"
            case .none: control = nil
            @unknown default: control = nil
            }
            return ["Ready", control].compactMap { $0 }.joined(separator: " · ")
        @unknown default:
            return "Unknown"
        }
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
