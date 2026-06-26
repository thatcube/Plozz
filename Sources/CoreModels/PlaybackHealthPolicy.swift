import Foundation

/// A sliding-window estimator for the **rate** at which an engine is shedding
/// late frames, computed purely from the cumulative `lateFrames` counter the
/// engine already exposes (no per-frame work).
///
/// The render-health watchdog must judge "is the device keeping up *right now*",
/// not "has it ever dropped a frame". An absolute count is useless for that — 633
/// late frames spread across a two-hour film is fine; 633 in ten seconds is a
/// device that can't render the stream. So we sample the monotonically-rising
/// cumulative counter on a fixed cadence, keep only the samples inside a short
/// trailing `window`, and report the delta over that window as frames-per-second.
///
/// Pure value type, no engine/AVFoundation dependency, so the math stays
/// unit-testable in `CoreModels` and the same estimate can drive both the
/// diagnostics overlay (display) and the watchdog (trip decision).
public struct LateFrameRateTracker: Equatable, Sendable {
    /// Trailing window the rate is measured over. Long enough to smooth a single
    /// noisy tick, short enough to react within a few seconds of a real stall.
    public let window: TimeInterval

    private struct Sample: Equatable, Sendable {
        var time: TimeInterval
        var lateFrames: Int
    }
    private var samples: [Sample] = []

    public init(window: TimeInterval = 5) {
        self.window = max(0.5, window)
    }

    /// Records a cumulative late-frame reading taken at `time` (a monotonic
    /// clock), evicting anything older than `window` before the newest sample.
    public mutating func record(cumulativeLateFrames: Int, at time: TimeInterval) {
        // Guard against a counter reset (engine swap / new stream): if the count
        // went backwards, restart the window so the delta can't go negative.
        if let last = samples.last, cumulativeLateFrames < last.lateFrames {
            samples.removeAll(keepingCapacity: true)
        }
        samples.append(Sample(time: time, lateFrames: cumulativeLateFrames))
        let cutoff = time - window
        // Keep one sample at/just before the cutoff so the delta spans the full
        // window, then drop the rest of the stale prefix.
        if let firstInWindow = samples.firstIndex(where: { $0.time >= cutoff }) {
            let keepFrom = firstInWindow > 0 ? firstInWindow - 1 : 0
            if keepFrom > 0 { samples.removeFirst(keepFrom) }
        }
    }

    /// Late frames per second across the current window, or `nil` until there are
    /// at least two samples spanning a meaningful span (so a single tick can't
    /// produce a bogus spike).
    public var ratePerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.time - first.time
        guard span >= 0.5 else { return nil }
        let delta = last.lateFrames - first.lateFrames
        guard delta >= 0 else { return nil }
        return Double(delta) / span
    }

    /// Clears all samples (call when (re)arming for a fresh stream).
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}

/// The data-driven, unit-tested policy behind the on-device **render-health
/// watchdog**: it decides, from cheap runtime signals, when an on-device engine
/// is failing to play the original acceptably and the player should degrade to
/// the existing server fallback chain.
///
/// Per Plozz's "direct play is king / build for flexibility" mandate this is a
/// *runtime safety net*, not a routing decision — the router still always picks
/// an on-device engine for direct play. This policy only fires when that engine
/// is measurably not keeping up on *this* hardware, which no static
/// codec/resolution fact can predict. Every threshold is a tunable field (mirror
/// of `MPVPlaybackTuning`) so Brandon can A/B-test the trip point on-device by
/// flipping a value rather than editing the watchdog.
///
/// Two independent failure shapes are covered:
///  * **Startup stall** — the stream never makes real progress (a silent
///    "loads forever" hang). Caught by `startupStallTimeout`.
///  * **Can't keep up** — playback *is* progressing but the engine sheds late
///    frames faster than a tunable rate for a sustained dwell (the lag Brandon
///    sees: mpv advancing but dropping frames on weak hardware). Caught by the
///    rate/dwell knobs below.
public struct PlaybackHealthPolicy: Equatable, Sendable {
    /// No real progress within this many seconds of arming → startup stall.
    /// Snappier than the old 30s so a genuine hang degrades fast instead of
    /// freezing the user on a spinner, while still clearing legitimate 4K
    /// start-up buffering.
    public var startupStallTimeout: TimeInterval

    /// Ignore the late-frame rate for this long after the *first* progress, so the
    /// initial decode/render warm-up and cache fill don't false-trip.
    public var startupWarmup: TimeInterval

    /// Trailing window the late-frame rate is averaged over (see
    /// `LateFrameRateTracker`).
    public var rateWindow: TimeInterval

    /// The late-frame rate must stay above threshold continuously for at least
    /// this long before tripping, so a brief network/seek hiccup can't flap the
    /// fallback.
    public var dwell: TimeInterval

    /// Threshold as a fraction of the source frame rate: dropping more than
    /// `lateRateFactorOfFPS × fps` frames per second means a large share of frames
    /// are missing their deadline. 0.5 ⇒ losing half the frames sustained.
    public var lateRateFactorOfFPS: Double

    /// Frame rate assumed when the source rate is unknown, so the threshold is
    /// still defined (most film/TV is ~24fps).
    public var assumedFrameRate: Double

    public init(
        startupStallTimeout: TimeInterval = 8,
        startupWarmup: TimeInterval = 5,
        rateWindow: TimeInterval = 5,
        dwell: TimeInterval = 5,
        lateRateFactorOfFPS: Double = 0.5,
        assumedFrameRate: Double = 24
    ) {
        self.startupStallTimeout = startupStallTimeout
        self.startupWarmup = startupWarmup
        self.rateWindow = rateWindow
        self.dwell = dwell
        self.lateRateFactorOfFPS = lateRateFactorOfFPS
        self.assumedFrameRate = assumedFrameRate
    }

    /// The shipped default. Conservative on false positives (5s warmup + 5s
    /// dwell) but fast once a device is genuinely drowning.
    public static let `default` = PlaybackHealthPolicy()

    /// Late frames/sec above which the engine is considered to be failing, given
    /// the source frame rate (falling back to `assumedFrameRate` when unknown).
    public func lateFrameRateThreshold(sourceFrameRate: Double?) -> Double {
        let fps = (sourceFrameRate.map { $0 > 0 ? $0 : assumedFrameRate }) ?? assumedFrameRate
        return lateRateFactorOfFPS * fps
    }

    /// `true` once enough time has passed since first progress that the late-frame
    /// rate is trustworthy (past the warm-up).
    public func isPastStartupWarmup(secondsSinceFirstProgress: TimeInterval) -> Bool {
        secondsSinceFirstProgress >= startupWarmup
    }

    /// Whether `rate` exceeds the trip threshold for the given source frame rate.
    public func isExcessiveLateFrameRate(_ rate: Double, sourceFrameRate: Double?) -> Bool {
        let threshold = lateFrameRateThreshold(sourceFrameRate: sourceFrameRate)
        return threshold > 0 && rate >= threshold
    }

    /// Startup-stall verdict: armed long enough with no real progress while not
    /// paused.
    public func isStartupStalled(
        secondsSinceArmed: TimeInterval,
        hasMadeProgress: Bool,
        isPaused: Bool
    ) -> Bool {
        !hasMadeProgress && !isPaused && secondsSinceArmed >= startupStallTimeout
    }

    /// Render-health verdict: playback is progressing but the engine has shed late
    /// frames above threshold continuously for at least `dwell`, past the warm-up,
    /// and is neither paused nor stalled. `secondsSustainedAboveThreshold` is the
    /// caller-maintained dwell timer (reset whenever the rate drops below
    /// threshold / playback pauses / position stops advancing).
    public func isFailingToKeepUp(
        secondsSinceFirstProgress: TimeInterval,
        isPaused: Bool,
        isProgressing: Bool,
        lateFrameRate: Double?,
        sourceFrameRate: Double?,
        secondsSustainedAboveThreshold: TimeInterval
    ) -> Bool {
        guard !isPaused, isProgressing else { return false }
        guard isPastStartupWarmup(secondsSinceFirstProgress: secondsSinceFirstProgress) else { return false }
        guard let rate = lateFrameRate, isExcessiveLateFrameRate(rate, sourceFrameRate: sourceFrameRate) else {
            return false
        }
        return secondsSustainedAboveThreshold >= dwell
    }
}
