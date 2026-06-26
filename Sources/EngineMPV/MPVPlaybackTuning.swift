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
/// "late" drops, the bottleneck is the renderer — try `videoOutput = "gpu"`
/// (the lighter classic GPU vo) for non-Dolby-Vision content.
public struct MPVPlaybackTuning: Sendable, Equatable {
    /// libmpv `--hwdec`. `videotoolbox` uses the Apple hardware decoder; `no`
    /// forces CPU decode (useful only to confirm a hardware-decode bug).
    public var hwdec: String
    /// libmpv `--vo`. `gpu-next` is libplacebo (best quality, needed for Dolby
    /// Vision RPU reshaping) but the heavier renderer; `gpu` is the lighter
    /// classic GPU output for when the device is render-bound on SDR/HDR10.
    public var videoOutput: String
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

    public init(
        hwdec: String = "videotoolbox",
        videoOutput: String = "gpu-next",
        cacheEnabled: Bool = true,
        demuxerReadaheadSecs: Int = 20,
        demuxerMaxBytes: String = "256MiB",
        demuxerMaxBackBytes: String = "64MiB"
    ) {
        self.hwdec = hwdec
        self.videoOutput = videoOutput
        self.cacheEnabled = cacheEnabled
        self.demuxerReadaheadSecs = demuxerReadaheadSecs
        self.demuxerMaxBytes = demuxerMaxBytes
        self.demuxerMaxBackBytes = demuxerMaxBackBytes
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
