import Foundation

/// Whether this device, playing this content, can afford Liquid Glass.
///
/// Glass is a live backdrop blur: every panel resamples what is behind it, every
/// frame. Over a still background that is nearly free. Over 4K Dolby Vision it
/// competes with the video pipeline for the same bandwidth, and the player is
/// exactly where the app draws the most glass at once.
///
/// Two independent signals, deliberately layered rather than merged:
///
///  * A **hardware floor**, fixed at launch. Some devices should never draw
///    glass over video at all.
///  * A **content ceiling**, raised and lowered as playback starts and stops.
///    Demanding video suspends glass for its duration and gets it back on exit.
///
/// Pure and synchronous so the rules can be tested without a device, a player,
/// or a running app — which matters, because the interesting cases are the ones
/// that are awkward to reproduce by hand.
public struct GlassPerformanceBudget: Equatable, Sendable {
    /// Devices below this never draw glass over video.
    ///
    /// Memory rather than a list of model identifiers, which is the same
    /// judgement `deviceModelName` had to make and gets stale every time Apple
    /// ships hardware: a new Apple TV with more memory passes this without a
    /// code change, where a model list would silently treat it as unknown.
    ///
    /// 3GB admits every Apple TV 4K (3GB on the 1st and 2nd generation, 4GB on
    /// the 3rd) and excludes the Apple TV HD, which has 2GB and an A8 — a chip
    /// that predates every part of this material.
    public static let minimumMemoryBytes: UInt64 = 3 * 1024 * 1024 * 1024

    /// Whether the hardware can draw glass at all.
    public var hardwareAllowsGlass: Bool

    /// Whether the content currently playing is demanding enough to suspend it.
    public var contentIsDemanding: Bool

    public init(hardwareAllowsGlass: Bool = true, contentIsDemanding: Bool = false) {
        self.hardwareAllowsGlass = hardwareAllowsGlass
        self.contentIsDemanding = contentIsDemanding
    }

    /// The budget for a device with this much memory.
    public static func forHardware(physicalMemoryBytes: UInt64) -> GlassPerformanceBudget {
        // A zero reading means the query failed, not that the device has no
        // memory. Failing open keeps a measurement bug from silently stripping
        // the interface on hardware that was fine.
        let allows = physicalMemoryBytes == 0 || physicalMemoryBytes >= minimumMemoryBytes
        return GlassPerformanceBudget(hardwareAllowsGlass: allows)
    }

    /// Whether glass should be suppressed on performance grounds alone.
    public var reducesTransparency: Bool {
        !hardwareAllowsGlass || contentIsDemanding
    }

    /// Whether a video with these characteristics should suspend glass.
    ///
    /// Judged from the SOURCE, before a frame is drawn, rather than from dropped
    /// frames after the fact. Reacting to drops means the viewer has already
    /// seen the stutter this exists to prevent, and the drop counter is only
    /// sampled while the diagnostics overlay is open — so it is not available
    /// when it would be needed.
    ///
    /// - Parameters:
    ///   - hdrFormat: the provider's own classification, which survives
    ///     transcoding because it describes the source rather than the asset
    ///     actually being played.
    ///   - width: coded width in pixels, when known.
    ///   - bitrate: source bitrate in bits per second, when known.
    ///
    /// Everything is optional and absence never counts against the content: a
    /// share with no metadata at all keeps its glass, because guessing that an
    /// unknown file is demanding would strip the interface for the viewers who
    /// can least afford to lose it.
    public static func contentIsDemanding(
        hdrFormat: PlaybackDiagnostics.HDRFormat?,
        width: Int?,
        bitrate: Double?
    ) -> Bool {
        // Dolby Vision at any size. Profile 5 and 8 carry a per-frame enhancement
        // layer and tone mapping that the display pipeline applies live, which is
        // the case this whole type was added for.
        if hdrFormat == .dolbyVision { return true }

        // 4K HDR of any flavour. The wide-gamut path costs more than SDR at the
        // same resolution, and at this size there is little headroom left.
        if let width, width >= 3_000, let hdrFormat, hdrFormat != .sdr { return true }

        // Very high bitrate regardless of format — a remuxed disc runs to
        // 60-100Mbps and saturates I/O and decode well before anything else
        // here notices.
        if let bitrate, bitrate >= 50_000_000 { return true }

        return false
    }

    /// Whether the source described by this metadata should suspend glass.
    ///
    /// Reads the PROVIDER's range tokens rather than anything AVFoundation
    /// reports, because a transcoded stream is delivered as SDR while the file
    /// being read, decoded and tone-mapped is still Dolby Vision — and it is the
    /// work, not the delivered format, that costs.
    public static func contentIsDemanding(source: MediaSourceMetadata?) -> Bool {
        guard let video = source?.video else { return false }
        let hdr = PlaybackDiagnostics.classifyHDR(
            videoRange: video.videoRange,
            videoRangeType: video.videoRangeType,
            colorTransfer: video.colorTransfer,
            isDolbyVision: (video.dolbyVisionProfile ?? 0) > 0
        )
        return contentIsDemanding(
            hdrFormat: hdr,
            width: video.width,
            bitrate: video.bitrate.map(Double.init)
        )
    }
}
