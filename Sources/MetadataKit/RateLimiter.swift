import Foundation

/// A small, concurrency-safe **token-bucket** rate limiter for being a polite
/// client of a keyless public API (notably lrclib.net, which asks callers to
/// stay around ~1 request/second).
///
/// `acquire()` reserves the next available time slot and sleeps only if the
/// caller is ahead of schedule. Because every reservation is computed
/// synchronously inside the actor *before* any sleep, concurrent callers each
/// get a distinct, monotonically increasing slot — there's no thundering herd
/// where everyone wakes up and fires at once.
///
/// ### Burst behaviour
/// A short burst (up to `burst` requests) is allowed to pass with no delay so a
/// single visible lyrics lookup — which fans out a few requests — still feels
/// instant. Sustained traffic beyond the burst is throttled to `spacing`
/// (= 1 / `requestsPerSecond`) between requests. After an idle gap the bucket
/// naturally refills, so the next visible lookup bursts through again.
public actor RateLimiter {
    /// Minimum spacing between sustained requests.
    private let spacing: TimeInterval
    /// How far ahead of "now" a caller may reserve before it has to wait.
    /// Equivalent to `burst` requests' worth of spacing.
    private let burstWindow: TimeInterval
    /// The earliest instant the next request is allowed to run.
    private var nextSlot: Date = .distantPast

    /// - Parameters:
    ///   - requestsPerSecond: Sustained ceiling once the burst is exhausted.
    ///   - burst: How many requests may fire back-to-back with no delay after
    ///     an idle period.
    public init(requestsPerSecond: Double, burst: Int) {
        let rps = max(requestsPerSecond, 0.0001)
        self.spacing = 1.0 / rps
        self.burstWindow = Double(max(burst, 1)) * (1.0 / rps)
    }

    /// Reserves the next slot and waits until the caller is allowed to proceed.
    /// Returns immediately when within the burst allowance.
    public func acquire() async {
        let now = Date()
        // Reserve a slot no earlier than now and no earlier than the previously
        // handed-out slot, then advance the cursor for the next caller.
        let reservation = max(now, nextSlot)
        nextSlot = reservation.addingTimeInterval(spacing)
        // Only sleep for the portion of the wait that exceeds the burst window,
        // so the first few requests after a quiet spell go out immediately.
        let wait = reservation.timeIntervalSince(now) - burstWindow
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
    }
}
