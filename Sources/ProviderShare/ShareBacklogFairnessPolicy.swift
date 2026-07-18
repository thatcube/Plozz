import Foundation

/// Pure backlog-ordering policy for `ShareMetadataWorkScheduler`.
///
/// The scheduler biases the active profile's shares ahead of passive backlog
/// retained for other profiles, but an unbounded bias starves other profiles. This
/// policy decides, from immutable facts only (which backlog accounts are preferred,
/// how long each has waited, and how many preferred admissions ran back-to-back),
/// the order in which backlog accounts should be *attempted*.
///
/// It owns no queue, job, admission, or persistence state — the scheduler passes a
/// snapshot in and applies the returned order. Urgent opened-item work is handled
/// entirely by the scheduler and remains globally first; this policy never sees it.
struct ShareBacklogFairnessPolicy: Sendable {
    /// One backlog account under consideration this dequeue.
    struct Candidate: Sendable, Equatable {
        var accountKey: String
        var isPreferred: Bool
        var enqueuedAt: ContinuousClock.Instant
    }

    /// After this many consecutive *preferred* backlog admissions, one runnable
    /// non-preferred account is surfaced ahead of the preferred bias so other
    /// profiles cannot be starved indefinitely. Must be at least 1.
    let preferredBurst: Int

    /// A non-preferred account that has waited at least this long is promoted ahead
    /// of the preferred bias regardless of the burst counter, so a long-waiting
    /// account still runs even under a steady stream of preferred work.
    let agePromotion: Duration

    init(preferredBurst: Int, agePromotion: Duration) {
        self.preferredBurst = max(1, preferredBurst)
        self.agePromotion = agePromotion
    }

    /// Returns the account keys to attempt, in order. FIFO ordering within the
    /// preferred and non-preferred classes is preserved (the caller supplies
    /// candidates in queue order).
    ///
    /// - `consecutivePreferredAdmissions` counts preferred backlog admissions that
    ///   actually ran back-to-back with no intervening non-preferred admission. The
    ///   scheduler updates it only on a real admission, so a blocked account can
    ///   never consume the burst quota.
    func order(
        candidates: [Candidate],
        consecutivePreferredAdmissions: Int,
        now: ContinuousClock.Instant
    ) -> [String] {
        let preferred = candidates.filter(\.isPreferred)
        let nonPreferred = candidates.filter { !$0.isPreferred }

        // Aging dominates: every non-preferred account past the age threshold, oldest
        // first, is surfaced ahead of the preferred bias. Bounded because a served
        // account restarts its age.
        let aged = nonPreferred
            .filter { $0.enqueuedAt.duration(to: now) >= agePromotion }
            .sorted { $0.enqueuedAt < $1.enqueuedAt }

        var front: [Candidate] = aged
        if front.isEmpty,
           consecutivePreferredAdmissions >= preferredBurst,
           let oldestNonPreferred = nonPreferred.min(by: { $0.enqueuedAt < $1.enqueuedAt }) {
            // Burst quota reached and no aged account: surface exactly one runnable
            // non-preferred account (oldest) ahead of the preferred bias.
            front = [oldestNonPreferred]
        }

        let placed = Set(front.map(\.accountKey))
        let remainder = preferred.filter { !placed.contains($0.accountKey) }
            + nonPreferred.filter { !placed.contains($0.accountKey) }
        return (front + remainder).map(\.accountKey)
    }
}
