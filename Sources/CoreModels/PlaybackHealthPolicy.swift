import Foundation

// MARK: - PlaybackHealthVerdict

/// The result of evaluating a running engine's start-up + render health.
///
/// `CoreModels` only names the *decision*; arming the watchdog, sampling the
/// engine, and running the fallback chain happen up in `FeaturePlayback`. Keeping
/// the policy here means it stays pure, dependency-free, and unit-testable on
/// Linux/CI — the same split the engine-routing brain uses.
public enum PlaybackHealthVerdict: String, Sendable, Equatable, CaseIterable {
    /// Playback is making progress and the render pipeline is keeping up — keep
    /// watching (or stop once the health window has elapsed).
    case healthy
    /// The stream never made real progress before the start-up deadline — a
    /// silent "loads forever" hang. The on-device engine should hand off to the
    /// fallback chain (try the alternate engine, then a server stream).
    case startupStalled
    /// Playback *is* advancing but the on-device engine is dropping/​arriving-late
    /// on too many frames to present smoothly — this device can't keep up with
    /// this stream. Degrade gracefully straight to a server stream (swapping to
    /// the other on-device engine won't make weak hardware faster, and for a
    /// Matroska source the native engine can't demux it at all).
    case cannotKeepUp
}

// MARK: - PlaybackHealthPolicy

/// The pure brain that decides — from cheap, sampled runtime facts — whether an
/// on-device playback engine is healthy, has stalled at start-up, or simply can't
/// keep up on this hardware. This is the policy behind the playback watchdog: it
/// turns "just lags forever / black screen" on weaker devices into an explicit,
/// testable signal that drives a graceful fallback to a server stream.
///
/// DIRECT PLAY stays the default everywhere (`EngineRouter`); a server stream is
/// strictly the *last resort*, reached only when the on-device path measurably
/// fails or can't keep up — never pre-emptively. This policy is what makes that
/// "last resort" fire fast and reliably instead of leaving the user stuck.
public struct PlaybackHealthPolicy: Sendable, Equatable {

    /// How long the watchdog waits for the *first* real progress before declaring
    /// a start-up stall. Snappy enough that a hang becomes a recovery in seconds,
    /// but generous enough for legitimate 4K start-up buffering on a slow link.
    public var startupStallTimeout: TimeInterval

    /// How long after first progress the render-health monitor keeps watching for
    /// "can't keep up". Bounded so the check is cheap and so legitimate later-in-
    /// playback events (a big seek) can't be mistaken for a hardware stall.
    public var renderHealthWindow: TimeInterval

    /// How many *additional* late/dropped frames (accumulated since playback first
    /// made progress, so start-up drops don't count) mark the engine as unable to
    /// keep up. Tuned to ignore the odd dropped frame while catching sustained jank.
    public var lateFrameStallThreshold: Int

    /// The default tuning: an 8s start-up deadline (down from a sluggish 30s), a
    /// 20s render-health window, and a 60-late-frame budget.
    public static let `default` = PlaybackHealthPolicy(
        startupStallTimeout: 8,
        renderHealthWindow: 20,
        lateFrameStallThreshold: 60
    )

    public init(
        startupStallTimeout: TimeInterval,
        renderHealthWindow: TimeInterval,
        lateFrameStallThreshold: Int
    ) {
        self.startupStallTimeout = startupStallTimeout
        self.renderHealthWindow = renderHealthWindow
        self.lateFrameStallThreshold = lateFrameStallThreshold
    }

    /// Evaluates one watchdog sample.
    ///
    /// - Parameters:
    ///   - secondsSinceArmed: wall-clock seconds since the watchdog was armed
    ///     around `engine.load()`.
    ///   - hasMadeProgress: whether playback position has advanced past its
    ///     start point (i.e. real frames are being presented).
    ///   - isPaused: whether the user paused (or playback was never asked to
    ///     play). A pause is never a stall — we must not fire a false positive.
    ///   - secondsSinceFirstProgress: wall-clock seconds since the first observed
    ///     progress, or `nil` if it hasn't progressed yet.
    ///   - lateFramesSinceFirstProgress: late/dropped frames accumulated since the
    ///     first observed progress, or `nil` when the engine can't report frame
    ///     health (e.g. the AVPlayer native engine, which is the efficient path we
    ///     never fall back *from*).
    /// - Returns: the health verdict for this sample.
    public func verdict(
        secondsSinceArmed: TimeInterval,
        hasMadeProgress: Bool,
        isPaused: Bool,
        secondsSinceFirstProgress: TimeInterval?,
        lateFramesSinceFirstProgress: Int?
    ) -> PlaybackHealthVerdict {
        // A pause is a deliberate stop, not a stall — never fire.
        if isPaused { return .healthy }

        // Start-up phase: nothing has played yet.
        guard hasMadeProgress else {
            return secondsSinceArmed >= startupStallTimeout ? .startupStalled : .healthy
        }

        // Render-health phase: playing, but is the device keeping up? Only judge
        // within the bounded window, and only when the engine reports frame health.
        if let since = secondsSinceFirstProgress, since <= renderHealthWindow,
           let late = lateFramesSinceFirstProgress, late >= lateFrameStallThreshold {
            return .cannotKeepUp
        }

        return .healthy
    }
}
