import Foundation

/// Performs the actual network writes for a drained ``WatchMutation``. The outbox
/// core stays provider-agnostic; `AppShell` supplies a concrete applier that
/// resolves an `accountID` to its `MediaProvider` (for played / resume writes) and
/// mirrors to Trakt.
///
/// Each method **throws on failure** so the reconciler keeps the target queued and
/// retries later. A throw is the *only* signal to retry — returning normally is
/// treated as a confirmed write (so a Trakt 409 must be swallowed as success by the
/// implementation, never rethrown).
public protocol WatchMutationApplying: Sendable {
    /// Marks `target` played/unplayed on its server (addressed by `target.itemID`).
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws
    /// Writes a resume position (seconds) to `target`'s server, session-lessly.
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget) async throws
    /// Mirrors a finished watch to Trakt. Must treat "already scrobbled" (409) as
    /// success and return normally.
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws

    /// Resolves the cross-server **twin targets** for an episode `mutation` — the
    /// same episode on every other server hosting the series, addressed by that
    /// server's own id. Best-effort and confidence-gated: returns only targets it
    /// is sure of, plus any accounts that couldn't be confirmed (so the reconciler
    /// retries them rather than dropping or guessing). The default returns
    /// ``WatchTargetExpansion/none`` so non-episode flows and test doubles need no
    /// expansion. Must never throw — a probe failure is expressed as an
    /// inconclusive account, not an error.
    func expandTargets(for mutation: WatchMutation) async -> WatchTargetExpansion
}

public extension WatchMutationApplying {
    func expandTargets(for mutation: WatchMutation) async -> WatchTargetExpansion { .none }
}

/// Drains the durable ``WatchOutboxState``: applies each pending mutation to every
/// server that still needs it (plus the optional Trakt mirror), idempotently,
/// dropping only writes that have been *superseded by a newer action* — never a
/// genuine watch.
///
/// An `actor` so enqueue and drain are serialized without locks; state is held in
/// memory and flushed to the injected ``WatchMutationStoring`` after every change,
/// so a kill mid-drain loses nothing.
///
/// Cold-start: constructed straight from `store.load()`, which is empty on a fresh
/// install — every method is safe on an empty queue (no force-unwraps).
public actor WatchStateReconciler {
    private let store: any WatchMutationStoring
    private let applier: any WatchMutationApplying
    private let now: @Sendable () -> Date
    /// How long a Trakt idempotency entry is honored before it's pruned. Must be
    /// ≥ ~24h (a Trakt scrobble cooldown window); defaulted generously to 48h.
    private let traktTTL: TimeInterval
    /// How long a stale-write clock entry is retained before pruning (housekeeping
    /// so the file can't grow unbounded). Long enough that an offline device coming
    /// back after a while is still protected from rewinds.
    private let clockTTL: TimeInterval

    private var state: WatchOutboxState
    private var isDraining = false
    private var drainRequestedWhileDraining = false

    public init(
        store: any WatchMutationStoring,
        applier: any WatchMutationApplying,
        now: @escaping @Sendable () -> Date = Date.init,
        traktTTL: TimeInterval = 48 * 3600,
        clockTTL: TimeInterval = 30 * 24 * 3600
    ) {
        self.store = store
        self.applier = applier
        self.now = now
        self.traktTTL = traktTTL
        self.clockTTL = clockTTL
        self.state = store.load()
    }

    /// Number of mutations still awaiting drain — for diagnostics / tests.
    public var pendingCount: Int { state.pending.count }

    /// A snapshot of the persisted state — for diagnostics / tests.
    public func snapshot() -> WatchOutboxState { state }

    // MARK: - Enqueue

    /// Records `mutation`'s intent durably, applying **stale-write suppression** and
    /// **coalescing** before the network is ever touched:
    ///  - If a newer action for the same title has already been accepted (clock),
    ///    this older write is stale and dropped (prevents resume creep / rewinds).
    ///  - If a not-yet-drained mutation for the same title is queued, the two
    ///    collapse into one (newest desired state wins, server targets unioned).
    ///
    /// Returns `true` if the mutation was accepted (or coalesced), `false` if it was
    /// dropped as stale.
    @discardableResult
    public func enqueue(_ mutation: WatchMutation) -> Bool {
        let key = mutation.coalesceKey

        // Stale-write suppression vs the accepted high-water mark.
        if let accepted = state.clock[key], mutation.capturedAt < accepted {
            persist()
            return false
        }

        if let index = state.pending.firstIndex(where: { $0.coalesceKey == key }) {
            let existing = state.pending[index]
            if mutation.capturedAt < existing.capturedAt {
                // Older than what's already queued — stale relative to the queue.
                return false
            }
            state.pending[index] = Self.coalesce(existing: existing, incoming: mutation)
        } else {
            state.pending.append(mutation)
        }

        state.clock[key] = max(state.clock[key] ?? .distantPast, mutation.capturedAt)
        persist()
        return true
    }

    /// Merges a newer mutation into an older queued one for the same title: the
    /// newer desired state wins, the server target sets are unioned (so a server
    /// either knew about collapses in), and the Trakt mirror is preserved if either
    /// carried one.
    static func coalesce(existing: WatchMutation, incoming: WatchMutation) -> WatchMutation {
        var merged = incoming
        merged.id = existing.id
        // Union targets, incoming first (keeps freshest providerKind), de-duped by id.
        var seen = Set<String>()
        merged.targets = (incoming.targets + existing.targets).filter { seen.insert($0.id).inserted }
        if incoming.trakt == nil, let carried = existing.trakt {
            merged.trakt = carried
            merged.traktPending = existing.traktPending
        }
        // Either side still owing twin expansion keeps it owed; preserve the origin
        // seed if the newer mutation lacked one (e.g. a mark-watched coalescing onto
        // a queued playback-stop).
        merged.expansionPending = incoming.expansionPending || existing.expansionPending
        if merged.episodeOrigin == nil { merged.episodeOrigin = existing.episodeOrigin }
        merged.attempts = existing.attempts
        return merged
    }

    // MARK: - Drain

    /// Attempts to apply every pending mutation. Best-effort and idempotent: a
    /// target that fails stays queued for the next drain; a target that succeeds is
    /// removed; a fully-applied mutation is pruned. Never drops a watch on failure —
    /// only supersession (a newer action) removes a pending write.
    public func drain() async {
        if isDraining {
            drainRequestedWhileDraining = true
            return
        }
        isDraining = true
        defer { isDraining = false }

        repeat {
            drainRequestedWhileDraining = false
            pruneExpired()
            // Iterate over a snapshot of ids so we can mutate `state.pending` safely.
            for mutationID in state.pending.map(\.id) {
                guard let index = state.pending.firstIndex(where: { $0.id == mutationID }) else { continue }
                var mutation = state.pending[index]

                // Supersession re-check at drain time.
                if let accepted = state.clock[mutation.coalesceKey], mutation.capturedAt < accepted {
                    state.pending.removeAll { $0.id == mutationID }
                    persist()
                    continue
                }

                await apply(&mutation)
                mutation.attempts += 1

                if let idx = state.pending.firstIndex(where: { $0.id == mutationID }) {
                    if mutation.isFullyApplied {
                        state.pending.remove(at: idx)
                    } else {
                        state.pending[idx] = mutation
                    }
                }
                persist()
            }
        } while drainRequestedWhileDraining
    }

    /// Applies a single mutation in place: each remaining server target, then the
    /// Trakt mirror. Successful writes are removed from the mutation so a partial
    /// fan-out resumes precisely.
    private func apply(_ mutation: inout WatchMutation) async {
        // Expand cross-server episode twins before writing, so a watch played from
        // one server fans out to the same episode on every server hosting the
        // series. Confidence-gated and best-effort: confident twins are unioned in
        // (deduped), and `expansionPending` is cleared only when the probe was
        // conclusive — an asleep/timed-out twin server keeps it pending so a later
        // drain retries. The origin target is already present and is written below
        // regardless, so expansion never delays or risks the origin write.
        if mutation.expansionPending {
            let expansion = await applier.expandTargets(for: mutation)
            var seen = Set(mutation.targets.map(\.id))
            for target in expansion.targets where seen.insert(target.id).inserted {
                mutation.targets.append(target)
            }
            if expansion.isConclusive {
                mutation.expansionPending = false
            }
        }

        var remaining: [WatchMutationTarget] = []
        for target in mutation.targets {
            do {
                if let played = mutation.played {
                    try await applier.setPlayed(played, on: target)
                }
                if let resume = mutation.resumePosition {
                    try await applier.setResumePosition(resume, on: target)
                } else if mutation.clearResume {
                    try await applier.setResumePosition(0, on: target)
                }
            } catch {
                remaining.append(target)
            }
        }
        mutation.targets = remaining

        if mutation.traktPending, let intent = mutation.trakt {
            let key = mutation.traktIdempotencyKey(dayBucket: WatchMutation.dayBucket(for: mutation.capturedAt))
            if state.appliedTrakt[key] != nil {
                mutation.traktPending = false
            } else {
                do {
                    try await applier.scrobbleTrakt(intent)
                    state.appliedTrakt[key] = now()
                    mutation.traktPending = false
                } catch {
                    // keep pending; retry next drain
                }
            }
        }
    }

    // MARK: - Housekeeping

    private func pruneExpired() {
        let cutoffTrakt = now().addingTimeInterval(-traktTTL)
        state.appliedTrakt = state.appliedTrakt.filter { $0.value >= cutoffTrakt }
        let cutoffClock = now().addingTimeInterval(-clockTTL)
        // Keep clock entries that still guard a queued mutation regardless of age.
        let activeKeys = Set(state.pending.map(\.coalesceKey))
        state.clock = state.clock.filter { $0.value >= cutoffClock || activeKeys.contains($0.key) }
    }

    private func persist() {
        try? store.save(state)
    }
}
