import Foundation

/// A point-in-time snapshot of an **engine's own runtime health** while a stream
/// plays — the "is the device actually struggling?" facts that the stream's
/// static description (codec/resolution/bitrate) can't answer.
///
/// Where `PlaybackDiagnostics` describes *what* is playing, `PlaybackEngineStats`
/// describes *how well the engine is keeping up*: whether decode is running on
/// the hardware decoder or has fallen back to the CPU, how many frames are being
/// dropped at decode (decoder can't keep up) vs at the output (render/timing
/// can't keep up), and the frame rate actually being rendered vs the stream's
/// target. The mpv engine fills these from libmpv properties; AVPlayer-based
/// playback leaves them `nil` (it surfaces drops through its own access log).
///
/// Pure value type, no AVFoundation/libmpv dependency, so classification and
/// formatting stay unit-testable in `CoreModels`.
public struct PlaybackEngineStats: Equatable, Sendable {
    /// Where the video is being decoded — the single most useful signal when the
    /// CPU "seems to be struggling": a hardware-decodable stream that has silently
    /// fallen back to **software** decode pegs the CPU and stutters.
    public enum DecodePath: String, Sendable {
        /// Decoding on a dedicated hardware decoder (e.g. VideoToolbox). Cheap.
        case hardware
        /// Decoding on the CPU. Expensive — the usual cause of "CPU struggling".
        case software
        /// The engine couldn't report a decode path.
        case unknown
    }

    /// Whether decode is running on hardware, the CPU, or is unknown.
    public var decodePath: DecodePath
    /// The engine's raw decoder name (e.g. `videotoolbox`, `lavc`/`no`), shown
    /// verbatim so an advanced user can see exactly what libmpv negotiated.
    public var hwdecName: String?
    /// Frames the **decoder** dropped because it couldn't keep up (the CPU/decode
    /// bottleneck signal). Cumulative for the session.
    public var decoderDroppedFrames: Int?
    /// Frames dropped/mistimed at the **output** stage (render or display-timing
    /// bottleneck, not decode). Cumulative for the session.
    public var lateFrames: Int?
    /// Frame rate actually being rendered right now (e.g. libmpv `estimated-vf-fps`).
    public var renderedFrameRate: Double?
    /// The stream's target/container frame rate, for comparison with rendered.
    public var containerFrameRate: Double?

    public init(
        decodePath: DecodePath = .unknown,
        hwdecName: String? = nil,
        decoderDroppedFrames: Int? = nil,
        lateFrames: Int? = nil,
        renderedFrameRate: Double? = nil,
        containerFrameRate: Double? = nil
    ) {
        self.decodePath = decodePath
        self.hwdecName = hwdecName
        self.decoderDroppedFrames = decoderDroppedFrames
        self.lateFrames = lateFrames
        self.renderedFrameRate = renderedFrameRate
        self.containerFrameRate = containerFrameRate
    }

    /// Classifies a raw libmpv `hwdec-current` string into a `DecodePath`.
    ///
    /// libmpv reports the active hardware decoder name (e.g. `videotoolbox`) when
    /// hardware decode engaged, or `no`/`""` when it is decoding on the CPU. Any
    /// other non-empty value is treated as a real hardware decoder.
    public static func decodePath(fromHWDecCurrent raw: String?) -> DecodePath {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .unknown
        }
        switch raw.lowercased() {
        case "no", "none": return .software
        default: return .hardware
        }
    }
}

// MARK: - Merge into a diagnostics snapshot

public extension PlaybackDiagnostics {
    /// Folds a live engine-health snapshot into this diagnostics value. Only
    /// non-nil/known fields overwrite, so a sparse sample never erases facts a
    /// richer one established.
    mutating func apply(engineStats stats: PlaybackEngineStats) {
        if stats.decodePath != .unknown { decodePath = stats.decodePath }
        if let name = stats.hwdecName { hwdecName = name }
        if let drops = stats.decoderDroppedFrames { engineDecoderDropFrames = drops }
        if let late = stats.lateFrames { engineLateFrames = late }
        if let fps = stats.renderedFrameRate, fps > 0 { renderedFrameRate = fps }
        if let fps = stats.containerFrameRate, fps > 0, frameRate == nil { frameRate = fps }
    }
}

// MARK: - Formatting (pure, unit-tested)

public extension PlaybackDiagnostics {
    /// Decode-path line, e.g. `Hardware (videotoolbox)` or `Software (CPU)`.
    /// `nil` when the engine reported no decode path (so the row hides).
    var decodeText: String? {
        switch decodePath {
        case .hardware:
            if let name = hwdecName, !name.isEmpty, name.lowercased() != "no" {
                return "Hardware (\(name))"
            }
            return "Hardware"
        case .software:
            return "Software (CPU)"
        case .unknown:
            return nil
        }
    }

    /// `true` when decode has fallen back to the CPU — the overlay flags this so
    /// the "CPU struggling" cause is obvious at a glance.
    var isSoftwareDecoding: Bool { decodePath == .software }

    /// Rendered-vs-target frame-rate line, e.g. `23.9 / 23.98 fps`, or just the
    /// rendered rate when no target is known. `nil` when the engine doesn't
    /// report a rendered rate (so the row hides).
    var renderRateText: String? {
        guard let rendered = renderedFrameRate, rendered > 0, rendered.isFinite else { return nil }
        let target = frameRate
        if let target, target > 0, target.isFinite {
            return String(format: "%.1f / %.2f fps", rendered, target)
        }
        return String(format: "%.1f fps", rendered)
    }

    /// Combined engine frame-drop line, e.g. `decoder 12 · late 3`. `nil` when the
    /// engine reports neither count (so the row hides for engines like AVPlayer
    /// that surface drops through the separate `Dropped` row instead).
    var engineDropsText: String? {
        var parts: [String] = []
        if let d = engineDecoderDropFrames { parts.append("decoder \(d)") }
        if let l = engineLateFrames { parts.append("late \(l)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Coarse main-thread responsiveness line driven by the sampler's measured
    /// scheduling slip, e.g. `OK` or `hitch 420 ms`. `nil` until measured.
    var mainThreadText: String? {
        guard let ms = mainThreadHitchMillis, ms >= 0 else { return nil }
        if ms < Self.mainThreadHitchThresholdMillis {
            return "OK"
        }
        return String(format: "hitch %.0f ms", ms)
    }

    /// `true` when the last measured main-thread slip crossed the hitch threshold,
    /// so the overlay can flag a UI/main-actor stall.
    var hasMainThreadHitch: Bool {
        guard let ms = mainThreadHitchMillis else { return false }
        return ms >= Self.mainThreadHitchThresholdMillis
    }

    /// Slip (ms) above the sampler's nominal 1s tick beyond which we call it a
    /// main-thread hitch. A healthy tick lands within a few tens of ms; a couple
    /// hundred ms of slip means the main actor was blocked.
    static let mainThreadHitchThresholdMillis: Double = 250
}
