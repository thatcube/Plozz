#if canImport(Libmpv) && canImport(UIKit)
import Foundation

/// Data-driven tuning for the libmpv engine's decode/render/cache behaviour.
///
/// Per Plozz's "build for flexibility" mandate, the knobs that affect playback
/// performance are **values**, not hardcoded option strings buried in `load()`,
/// so a default can be changed (or A/B-tested on-device) by flipping a field
/// rather than editing the engine. The shipped `.default` mirrors the previously
/// hardcoded behaviour plus a slightly larger network read-ahead for smoother
/// direct play; the colorimetry / HDR options stay in the engine because they're
/// computed per-stream from the source metadata.
///
/// On-device triage flow: turn on the Diagnostics overlay and read the **Decode**
/// row. If it shows `Software (CPU)`, decode never reached VideoToolbox — try a
/// different `hwdec`. If it shows `Hardware` but Render fps sits below target with
/// "late" drops, the renderer is the bottleneck: SDR already uses the lighter
/// `gpu` vo here; for HDR/Dolby-Vision (which needs `gpu-next`) the lever is the
/// `videoOutput` field.
public struct MPVPlaybackTuning: Sendable, Equatable {
    /// libmpv `--hwdec`. `videotoolbox` uses the Apple hardware decoder; `no`
    /// forces CPU decode (useful only to confirm a hardware-decode bug).
    public var hwdec: String
    /// libmpv `--vo` for HDR/Dolby Vision. `gpu-next` is libplacebo — the best
    /// quality and the only renderer that can reshape the Dolby Vision RPU to PQ —
    /// but it's the heavier path (per-frame libplacebo shaders on the
    /// Vulkan→MoltenVK→Metal present chain). Required for HDR; do not change.
    public var videoOutput: String
    /// libmpv `--vo` for SDR content. Defaults to the lighter classic `gpu`
    /// renderer: SDR never needs libplacebo's tone-mapping / RPU reshaping, and on
    /// Apple TV the gpu-next present path was missing frame deadlines (showing as
    /// "late" drops in the diagnostics overlay) even on trivial 1080p direct play.
    /// `gpu` removes that per-frame libplacebo cost while leaving HDR/DV untouched.
    public var sdrVideoOutput: String
    /// Whether to enable libmpv's stream cache (`--cache`). On for smooth
    /// network direct play.
    public var cacheEnabled: Bool
    /// libmpv `--demuxer-readahead-secs`: how far ahead to keep demuxed packets,
    /// smoothing brief network hiccups during direct play.
    public var demuxerReadaheadSecs: Int
    /// libmpv `--demuxer-max-bytes`: forward demuxer cache ceiling.
    public var demuxerMaxBytes: String
    /// libmpv `--demuxer-max-back-bytes`: backward demuxer cache ceiling (cheap
    /// instant back-seeks without a re-read).
    public var demuxerMaxBackBytes: String
    /// libmpv `--video-sync`. Defaults to `display-resample`: time video to the
    /// display's vsync (resampling audio by an inaudible fraction) so each frame
    /// is presented exactly on a refresh. Paired with SDR frame-rate matching —
    /// which drives the panel to the content's rate — this is what removes the
    /// residual "late frames" that `audio` sync leaves behind (with `audio`, mpv
    /// times to the audio clock, so presents drift past the vsync deadline and
    /// show as late even on a matched panel). The feared GPU cost is from
    /// `interpolation`, NOT from `display-resample` itself: on a frame-rate-matched
    /// panel the display ≈ content rate, so resample is ~1:1 and adds no per-frame
    /// libplacebo shaders. Set to `audio` (or `nil` to leave mpv's default, which
    /// is also `audio`) to A/B the lighter clock on weaker hardware.
    public var videoSync: String?
    /// libmpv `--interpolation`. Off by default: it only helps when the display
    /// rate doesn't divide the source rate (which frame-rate matching is meant to
    /// avoid) and IS the expensive present-path option (the per-frame libplacebo
    /// cost), so enabling it is an explicit, measured opt-in.
    public var interpolation: Bool

    public init(
        hwdec: String = "videotoolbox",
        videoOutput: String = "gpu-next",
        sdrVideoOutput: String = "gpu",
        cacheEnabled: Bool = true,
        demuxerReadaheadSecs: Int = 20,
        demuxerMaxBytes: String = "256MiB",
        demuxerMaxBackBytes: String = "64MiB",
        videoSync: String? = "display-resample",
        interpolation: Bool = false
    ) {
        self.hwdec = hwdec
        self.videoOutput = videoOutput
        self.sdrVideoOutput = sdrVideoOutput
        self.cacheEnabled = cacheEnabled
        self.demuxerReadaheadSecs = demuxerReadaheadSecs
        self.demuxerMaxBytes = demuxerMaxBytes
        self.demuxerMaxBackBytes = demuxerMaxBackBytes
        self.videoSync = videoSync
        self.interpolation = interpolation
    }

    /// The renderer to use for a stream: the heavier libplacebo `gpu-next` only
    /// when HDR/Dolby Vision actually needs it, otherwise the lighter `gpu`.
    func videoOutput(isHDR: Bool) -> String {
        isHDR ? videoOutput : sdrVideoOutput
    }

    /// The shipped default: previous decode/render behaviour plus smoother
    /// direct-play caching.
    public static let `default` = MPVPlaybackTuning()

    /// The cache/demuxer option pairs to apply before `mpv_initialize`, in a
    /// deterministic order. Decode (`hwdec`) and output (`vo`) are applied by the
    /// engine alongside the colorimetry options they're coupled to.
    func cacheOptionPairs() -> [(String, String)] {
        [
            ("cache", cacheEnabled ? "yes" : "no"),
            ("demuxer-readahead-secs", String(demuxerReadaheadSecs)),
            ("demuxer-max-bytes", demuxerMaxBytes),
            ("demuxer-max-back-bytes", demuxerMaxBackBytes)
        ]
    }
}
#endif
