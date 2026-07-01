import Foundation

/// Env-gated stdout tracer for the seek / end-of-stream / engine-state path.
///
/// Why this exists: `os_log` is **not** readable off a network-paired Apple TV on
/// this toolchain, so the only way to watch playback decisions live is to mirror
/// them to stdout and capture them with
/// `xcrun devicectl device process launch --console`. This is the same pattern as
/// `PLZSCRUB` (``ScrubDiagnostics``) / `PLZXFAN` — one tagged line per event.
///
/// Tag: `PLZSEEK`. Enable with `SEEK_DIAG=1` (or the existing `SCRUB_DIAG=1`, so a
/// single launch flag captures both). Zero-cost when unset: every call early-outs
/// on `enabled` before touching `Date`/`FileHandle`.
///
/// Use it to answer the questions the seek path can't otherwise: did
/// `engine.seek` actually return? did the engine emit `.ended` while the viewer
/// was scrubbing? did a `.ended` dismiss race a backward seek? It is purely
/// diagnostic — it never changes behavior.
public enum PlaybackTrace {
    /// Gate on an env var so it's free in normal runs. Reads `SEEK_DIAG` first,
    /// then `SCRUB_DIAG` (the flag the existing console-capture flow already sets).
    public static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["SEEK_DIAG"] == "1" || env["SCRUB_DIAG"] == "1"
    }()

    /// Emit one `PLZSEEK <t> <message>` line to stdout. `<t>` is wall-clock seconds
    /// (mod 100000) to 3 dp, enough to order events and measure gaps within a
    /// capture. No-op unless ``enabled``.
    public static func note(_ message: String) {
        guard enabled else { return }
        let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100_000)
        let line = "PLZSEEK " + String(format: "%.3f", t) + " " + message + "\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
    }
}
