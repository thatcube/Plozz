import Foundation

/// A small, concurrency-safe **token-bucket** rate limiter for being a polite
/// client of a keyless public API (notably lrclib.net, which asks callers to
/// stay around ~1 request/second).
///
/// The bucket starts full with `burst` tokens and refills continuously at
/// `requestsPerSecond`. `acquire()` consumes one token, waiting only when the
/// bucket is empty. A short burst (up to `burst` requests) passes with no delay
/// so a single visible lyrics lookup — which fans out a few requests — still
/// feels instant; sustained traffic beyond the burst is throttled toward
/// `requestsPerSecond`.
///
/// ### Why a token bucket (and not a reservation cursor)
/// An earlier version handed out monotonically increasing time slots and
/// advanced a `nextSlot` cursor on every `acquire()`. That is fatal under heavy
/// cancellation: the lyrics layer fires many *prefetch* requests that are
/// routinely cancelled the instant the user skips. Each had already pushed
/// `nextSlot` seconds into the future and never rolled it back, so the schedule
/// stayed poisoned — the next **visible** track's request inherited a
/// multi-second reservation and was itself cancelled before it ever ran. LRCLIB
/// lookups then only succeeded once the user stopped skipping and the phantom
/// backlog drained.
///
/// A token bucket is inherently cancellation-safe: a token is consumed **only**
/// when one is actually available, *after* any wait. A request cancelled while
/// waiting consumes nothing and leaves the bucket untouched, so it cannot delay
/// later callers. Freshly arriving requests also naturally proceed as soon as a
/// token is free rather than queueing behind stale, abandoned reservations.
public actor RateLimiter {
    /// Maximum tokens the bucket can hold (the burst allowance).
    private let capacity: Double
    /// Tokens replenished per second once the burst is spent.
    private let refillPerSecond: Double
    /// Currently available tokens (fractional between whole requests).
    private var tokens: Double
    /// When `tokens` was last brought up to date.
    private var lastRefill: Date

    /// - Parameters:
    ///   - requestsPerSecond: Sustained ceiling once the burst is exhausted.
    ///   - burst: How many requests may fire back-to-back with no delay after
    ///     an idle period.
    public init(requestsPerSecond: Double, burst: Int) {
        self.refillPerSecond = max(requestsPerSecond, 0.0001)
        self.capacity = Double(max(burst, 1))
        self.tokens = self.capacity
        self.lastRefill = Date()
    }

    /// Consumes one token, waiting until one is available. Returns immediately
    /// when within the burst allowance. If the calling task is cancelled while
    /// waiting, returns **without** consuming a token so the cancellation can't
    /// affect other callers' pacing.
    public func acquire() async {
        while true {
            refill()
            if tokens >= 1 {
                tokens -= 1
                return
            }
            // Bucket empty: wait just long enough for one token to accrue.
            let wait = (1 - tokens) / refillPerSecond
            try? await Task.sleep(for: .seconds(wait))
            // A cancelled wait must not consume a token — bail and let the
            // caller's own cancellation handling (its HTTP request will throw)
            // take over, leaving the bucket intact for live requests.
            if Task.isCancelled { return }
        }
    }

    /// Brings `tokens` up to date for the time elapsed since the last refill,
    /// clamped to `capacity`.
    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        if elapsed > 0 {
            tokens = min(capacity, tokens + elapsed * refillPerSecond)
            lastRefill = now
        }
    }
}
