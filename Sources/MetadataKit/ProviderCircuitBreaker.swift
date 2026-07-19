import Foundation
import CoreModels

/// An independent, per-provider circuit breaker.
///
/// Each provider owns its own breaker, so one source being down (offline, 401, 429)
/// never blocks another — the pipeline just skips the tripped source and degrades to
/// cached / last-known for it. Cooldowns are **kind-specific and independent**:
///   * transient failures (offline / 5xx / timeout) open only after a threshold of
///     consecutive failures, for a short cooldown;
///   * `401/403` opens immediately for a longer auth cooldown (credentials must
///     change);
///   * `429` opens honoring the server's `Retry-After` when provided, else a
///     fallback.
///
/// After a cooldown elapses the breaker is *half-open*: it admits one probe. A
/// successful (or authoritatively empty) probe closes it and reports **recovery**, so
/// the caller can drop that provider's stale negatives and refill gaps immediately.
public actor ProviderCircuitBreaker {
    public struct Policy: Sendable, Equatable {
        /// Consecutive transient failures required to trip.
        public var failureThreshold: Int
        public var transientCooldown: TimeInterval
        public var authCooldown: TimeInterval
        /// Used for a 429 that carries no `Retry-After`.
        public var rateCooldownFallback: TimeInterval

        public init(
            failureThreshold: Int = 3,
            transientCooldown: TimeInterval = 60,
            authCooldown: TimeInterval = 300,
            rateCooldownFallback: TimeInterval = 60
        ) {
            self.failureThreshold = max(1, failureThreshold)
            self.transientCooldown = transientCooldown
            self.authCooldown = authCooldown
            self.rateCooldownFallback = rateCooldownFallback
        }
    }

    private let policy: Policy
    private let now: @Sendable () -> Date
    private var openUntil: Date?
    private var openReason: ProviderFailureKind?
    private var consecutiveTransient = 0
    /// Set once a half-open probe has been admitted, so only ONE caller probes a
    /// just-recovering source; cleared by the next ``record(_:)`` (success or failure).
    private var probeInFlight = false

    public init(policy: Policy = Policy(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.policy = policy
        self.now = now
    }

    /// Whether a call may proceed now, **consuming** a half-open probe slot when the
    /// breaker is tripped-but-cooled-down. Returns `true` when closed, or exactly once
    /// per cooldown when half-open (admitting a single probe); returns `false` while
    /// cooling down, and for every other caller until the probe's ``record(_:)``
    /// resolves it — preventing a thundering herd against a recovering source.
    public func allow() -> Bool {
        guard let until = openUntil else { return true } // closed
        if now() < until { return false }                // still cooling down
        if probeInFlight { return false }                // a probe is already out
        probeInFlight = true                             // admit exactly one probe
        return true
    }

    /// Whether the breaker is currently tripped (open and still cooling down).
    public var isTripped: Bool {
        guard let until = openUntil else { return false }
        return now() < until
    }

    /// The reason the breaker is open, if tripped.
    public var trippedReason: ProviderFailureKind? { isTripped ? openReason : nil }

    /// The breaker's tripped state **and** reason read together in one actor hop, so
    /// a caller can't observe a torn `isTripped: true` / `reason: nil` across two
    /// separate awaits (Step 6 diagnostics read these together).
    public var trippedState: (isTripped: Bool, reason: ProviderFailureKind?) {
        let tripped = isTripped
        return (tripped, tripped ? openReason : nil)
    }

    /// Records the outcome of a call.
    /// - Returns: `true` when this recorded a *recovery* — the breaker was open and a
    ///   healthy result (ok / authoritative empty) closed it — so the caller can
    ///   refill that provider's previously-cached gaps.
    @discardableResult
    public func record(_ health: ProviderHealth) -> Bool {
        probeInFlight = false
        switch health {
        case .ok, .empty:
            let wasOpen = openUntil != nil
            consecutiveTransient = 0
            openUntil = nil
            openReason = nil
            return wasOpen
        case .failure(let kind):
            switch kind {
            case .transient:
                consecutiveTransient += 1
                if consecutiveTransient >= policy.failureThreshold {
                    trip(kind, cooldown: policy.transientCooldown)
                }
            case .unauthorized:
                trip(kind, cooldown: policy.authCooldown)
            case .rateLimited(let retryAfter):
                trip(kind, cooldown: max(0, retryAfter ?? policy.rateCooldownFallback))
            }
            return false
        }
    }

    /// Force the breaker closed and clear failure state — used when a provider's
    /// credentials change, so it is retried immediately regardless of an auth cooldown.
    public func reset() {
        openUntil = nil
        openReason = nil
        consecutiveTransient = 0
        probeInFlight = false
    }

    private func trip(_ reason: ProviderFailureKind, cooldown: TimeInterval) {
        openUntil = now().addingTimeInterval(cooldown)
        openReason = reason
    }
}
