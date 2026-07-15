import Foundation

/// Feature gate for the **experimental double-buffered hero foreground**.
///
/// Measured evidence (thermal-nominal, 4s untouched auto-advance, remote PLZPERF
/// capture) showed the Home hero's *foreground* SwiftUI tree re-diff is 100% of
/// the paging hitch: the full transition is ~40ms / ~1.4 hitches, while the real
/// backdrop wipe with the foreground omitted is 17ms / zero hitches. Nothing in
/// the foreground (image resolution, metadata fade, Liquid Glass, dots, a11y,
/// logo, geometry preferences, equality guards) was individually causal — it is
/// the whole tree being rebuilt on the transition frame.
///
/// This gate turns on a prepared / double-buffered rendering path (the buffered
/// `HomeHeroView` methods driven by `HeroForegroundBuffers`) that
/// pre-builds the adjacent slides' *visual* foreground during the dwell and, on a
/// page, swaps an already-built buffer in without rebuilding it on the transition
/// frame — while keeping exactly one stable, interactive focus overlay.
///
/// **Default OFF.** With the gate off the hero renders its original, shipped
/// single-foreground path byte-for-byte; production / `main` behavior is
/// unchanged until an explicitly-authorized on-device A/B test proves the
/// buffered path wins. Enable for that test by launching the app with the
/// environment variable `PLZHERO_BUFFERED_FOREGROUND=1`.
///
/// Follows the same env-var, read-once, Linux-safe pattern as
/// ``HeroFocusDiagnostics`` / ``HomePerfDiagnostics``.
enum HeroForegroundExperiment {
    /// Whether the experimental double-buffered foreground path is active. Read
    /// once at process start from `PLZHERO_BUFFERED_FOREGROUND` (`"1"` = on).
    /// Off by default so shipped/main runs use the standard path.
    static let isBufferedForegroundEnabled: Bool =
        ProcessInfo.processInfo.environment["PLZHERO_BUFFERED_FOREGROUND"] == "1"
}
