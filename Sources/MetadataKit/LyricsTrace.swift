import Foundation

/// Lightweight, opt-in, DEBUG-only trace for the lyrics resolution pipeline.
///
/// TEMPORARY diagnostic: added to validate the prefetch-negative (H1a) and
/// duration-version-ceiling (M2) fixes on-device by watching resolution as the
/// user skips through songs. Safe to delete once verified.
///
/// Enabled at launch only when the `PLOZZ_LYRICS_TRACE` environment variable is
/// set to a non-empty value, so ordinary debug runs stay silent. Compiled out
/// entirely in Release (`emit` becomes a no-op and the `@autoclosure` message is
/// never evaluated, so there's zero cost when off). Lines go to stdout with a
/// `🎤LYR` prefix so they show in `xcrun devicectl … process launch --console`
/// and are trivially greppable.
public enum LyricsTrace {
    #if DEBUG
    public static let isEnabled: Bool =
        !(ProcessInfo.processInfo.environment["PLOZZ_LYRICS_TRACE"] ?? "").isEmpty
    #endif

    @inline(__always)
    public static func emit(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard isEnabled else { return }
        print("🎤LYR \(message())")
        #endif
    }
}
