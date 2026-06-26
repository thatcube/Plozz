import Foundation

/// Pure decision logic for tvOS **frame-rate (refresh-rate) matching**.
///
/// AVPlayer automatically switches the Apple TV's HDMI output to a refresh rate
/// that matches the source's frame rate (when the user's "Match Frame Rate"
/// setting is on) — a 23.976fps file drives the panel into a 24Hz-family mode so
/// every source frame maps to a single refresh with no 23.98→60 cadence. The
/// custom mpv engine has to drive `AVDisplayManager.preferredDisplayCriteria`
/// itself to get the same behaviour; previously it only did so for HDR content,
/// leaving SDR files cadenced at 60Hz (the "late frames" Brandon saw).
///
/// This helper isolates the *decision* — given a source frame rate, what refresh
/// rate (if any) should we ask tvOS to match — so it is trivially unit-testable
/// without an engine or a display. It deliberately knows nothing about
/// colorimetry or `AVDisplayCriteria`; the engine builds the criteria from the
/// returned rate.
public enum FrameRateMatching {
    /// The widest plausible source frame-rate window we'll request a match for.
    /// Below 1fps or above 480fps is almost certainly bogus metadata (or a
    /// still/slideshow), so we leave the display alone rather than ask tvOS for a
    /// nonsensical mode.
    public static let minFrameRate: Double = 1
    public static let maxFrameRate: Double = 480

    /// The refresh rate to request a display match for, or `nil` to leave the
    /// display untouched.
    ///
    /// Returns `nil` (a true no-op — the caller requests *no* switch) when the
    /// source frame rate is unknown, zero/negative, or outside the plausible
    /// `minFrameRate...maxFrameRate` window. This is the graceful-degradation
    /// path: a file with no frame-rate metadata never yanks the panel into a
    /// guessed mode, so playback is never made worse than leaving the display as
    /// it is.
    ///
    /// The returned value is the source frame rate itself (as `Float`, the type
    /// `AVDisplayCriteria(refreshRate:formatDescription:)` expects). tvOS maps it
    /// onto the nearest supported mode in the same family (e.g. 23.976 → a
    /// 24Hz-family mode), and ignores the request entirely if the user disabled
    /// "Match Frame Rate", so we don't have to special-case integer vs fractional
    /// rates here.
    public static func refreshRate(forSourceFrameRate frameRate: Double?) -> Float? {
        guard let frameRate, frameRate >= minFrameRate, frameRate <= maxFrameRate else {
            return nil
        }
        return Float(frameRate)
    }

    /// Whether a refresh-rate match should be requested for the given source
    /// frame rate. Convenience mirror of `refreshRate(forSourceFrameRate:)` for
    /// call sites and tests that only care about the yes/no decision.
    public static func shouldMatch(sourceFrameRate frameRate: Double?) -> Bool {
        refreshRate(forSourceFrameRate: frameRate) != nil
    }
}
