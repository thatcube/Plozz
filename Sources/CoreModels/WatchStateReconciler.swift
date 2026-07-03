import Foundation

/// Performs the actual network writes for a drained ``WatchMutation``. The outbox
/// core stays provider-agnostic; `AppShell` supplies a concrete applier that
/// resolves an `accountID` to its `MediaProvider` (for played / resume writes) and
/// mirrors to external trackers (Trakt, Simkl, AniList, MAL).
///
/// Each method **throws on failure** so the reconciler keeps the target queued and
/// retries later. A throw is the *only* signal to retry — returning normally is
/// treated as a confirmed write (so a Trakt 409 must be swallowed as success by the
/// implementation, never rethrown).
public protocol WatchMutationApplying: Sendable {
    /// Marks `target` played/unplayed on its server (addressed by `target.itemID`).
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws
    /// Marks `target` played/unplayed with the play's real `capturedAt`, for a
    /// provider whose played state is stored **locally** and ordered
    /// last-writer-wins (the SMB share). Defaults to the timestamp-less
    /// ``setPlayed(_:on:)`` for a server-backed provider that ignores capture time.
    func setPlayed(_ played: Bool, on target: WatchMutationTarget, capturedAt: Date) async throws
    /// Writes a resume position (seconds) to `target`'s server, session-lessly.
    /// `capturedAt` is the play's real timestamp (see ``ResumeStateWriting``), used
    /// for the server's recency stamp so an offline-drained write doesn't falsely
    /// float a stale title to the top of Continue Watching.
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws
    /// Mirrors a finished watch to Trakt.
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws
    /// Mirrors a finished watch to Simkl.
    func scrobbleSimkl(_ intent: TraktScrobbleIntent) async throws
    /// Mirrors a finished watch to AniList (anime only).
    func scrobbleAniList(_ intent: TraktScrobbleIntent) async throws
    /// Mirrors a finished watch to MyAnimeList (anime only).
    func scrobbleMAL(_ intent: TraktScrobbleIntent) async throws

    /// Resolves the cross-server **twin targets** for an episode `mutation`.
    func expandTargets(for mutation: WatchMutation) async -> WatchTargetExpansion
}

public extension WatchMutationApplying {
    func setPlayed(_ played: Bool, on target: WatchMutationTarget, capturedAt: Date) async throws {
        try await setPlayed(played, on: target)
    }
    func expandTargets(for mutation: WatchMutation) async -> WatchTargetExpansion { .none }
    func scrobbleSimkl(_ intent: TraktScrobbleIntent) async throws {}
    func scrobbleAniList(_ intent: TraktScrobbleIntent) async throws {}
    func scrobbleMAL(_ intent: TraktScrobbleIntent) async throws {}
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
    /// How long an ``AppliedResumeRecord`` is retained (device clock, by
    /// `appliedAt`). Kept short: it only needs to bridge a drain to the next Home
    /// reload (both around app-foreground), and a short window guarantees a stale
    /// record can never override a genuine later play made on another client.
    private let resumeRecencyTTL: TimeInterval

    private var state: WatchOutboxState
    private var isDraining = false
    private var drainRequestedWhileDraining = false

    /// `(accountID:itemID)` keys (matching ``WatchMutationTarget/id``) that have a
    /// **live in-app playback session** right now. The reconciler never issues a
    /// convergence write against one of these targets — the live player already
    /// owns that server's now-playing session, and an out-of-band write (even via
    /// the session-less endpoints) is deferred until playback ends so a mid-play
    /// drain can't race/disturb/zero the live session. Purely in-memory and never
    /// persisted: a kill mid-play simply forgets the guard, so a relaunch drains
    /// everything normally (durability preserved). Deferral ≠ drop — a guarded
    /// target stays queued and converges on ``endLiveSession(accountID:itemID:)``.
    private var liveSessions: Set<String> = []

    public init(
        store: any WatchMutationStoring,
        applier: any WatchMutationApplying,
        now: @escaping @Sendable () -> Date = Date.init,
        traktTTL: TimeInterval = 48 * 3600,
        clockTTL: TimeInterval = 30 * 24 * 3600,
        resumeRecencyTTL: TimeInterval = 30 * 60
    ) {
        self.store = store
        self.applier = applier
        self.now = now
        self.traktTTL = traktTTL
        self.clockTTL = clockTTL
        self.resumeRecencyTTL = resumeRecencyTTL
        self.state = store.load()
    }

    /// Number of mutations still awaiting drain — for diagnostics / tests.
    public var pendingCount: Int { state.pending.count }

    /// A snapshot of the persisted state — for diagnostics / tests.
    public func snapshot() -> WatchOutboxState { state }

    // MARK: - Live playback guard

    /// Marks `(accountID, itemID)` as the live in-app playback session, so the
    /// reconciler defers (never issues) convergence writes against it until the
    /// session ends. Idempotent — registering the same session twice is a no-op.
    /// The live player itself keeps that server's now-playing session in sync; the
    /// outbox only converges the *other* servers + provides durability.
    public func beginLiveSession(accountID: String, itemID: String) {
        liveSessions.insert(WatchMutationTarget(accountID: accountID, itemID: itemID).id)
    }

    /// Ends the live session for `(accountID, itemID)` and drains, so any writes
    /// that were deferred *because* it was playing now converge. Idempotent.
    public func endLiveSession(accountID: String, itemID: String) async {
        liveSessions.remove(WatchMutationTarget(accountID: accountID, itemID: itemID).id)
        await drain()
    }

    /// Whether `(accountID, itemID)` is currently a guarded live session — for
    /// diagnostics / tests.
    public func isLiveSession(accountID: String, itemID: String) -> Bool {
        liveSessions.contains(WatchMutationTarget(accountID: accountID, itemID: itemID).id)
    }

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
        // Preserve pending tracker flags from either side (either still owed keeps it owed).
        merged.simklPending = incoming.simklPending || existing.simklPending
        merged.anilistPending = incoming.anilistPending || existing.anilistPending
        merged.malPending = incoming.malPending || existing.malPending
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
                    // Actor reentrancy guard. `apply` suspends on the network, and
                    // this reconciler is an actor, so a concurrently-enqueued NEWER
                    // action for the same `coalesceKey` can run during that
                    // suspension: `enqueue` → `coalesce` keeps the same entry id but
                    // bumps `capturedAt`, unions the target set, and advances the
                    // clock. Our local `mutation` copy is now stale. Writing it back
                    // would clobber the newer desired state (played / resumePosition)
                    // and the unioned targets; and if our OLD copy happened to be
                    // fully applied, `remove(at:)` would DROP the newer action
                    // entirely — the classic "Continue Watching reverted to what I
                    // watched before" loss. Detect the coalesce by `capturedAt`
                    // advancing and leave the live (newer) entry untouched, requesting
                    // a follow-up drain to apply it. Every server / tracker write is
                    // idempotent (setting played/resume is a no-op if already set, and
                    // the applied-caches suppress duplicate scrobbles), so re-applying
                    // the shared targets on the next drain is safe.
                    if state.pending[idx].capturedAt > mutation.capturedAt {
                        drainRequestedWhileDraining = true
                    } else if mutation.isFullyApplied {
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
            FanoutDiagnostics.emit(
                "drain.expand canonical=\(mutation.canonicalMediaID) "
                + "addedTwins=\(expansion.targets.count) conclusive=\(expansion.isConclusive) "
                + "inconclusiveAccts=\(expansion.inconclusiveAccountIDs)")
        }

        // (d) The full target set about to be written (post-expansion), so the drain
        // is visible end-to-end alongside the stop event.
        FanoutDiagnostics.emit(FanoutDiagnostics.drainHeaderLine(
            canonicalMediaID: mutation.canonicalMediaID,
            played: mutation.played,
            resumePosition: mutation.resumePosition,
            clearResume: mutation.clearResume,
            targets: mutation.targets,
            expansionPending: mutation.expansionPending
        ))

        var remaining: [WatchMutationTarget] = []
        for target in mutation.targets {
            // Never write to a target that is the live in-app playback session:
            // defer it (keep it queued) so a mid-play drain can't disturb the
            // now-playing session. The live player owns that server; the deferred
            // write converges when the session ends (endLiveSession drains).
            if liveSessions.contains(target.id) {
                remaining.append(target)
                FanoutDiagnostics.emit(FanoutDiagnostics.drainTargetLine(target, outcome: "deferred(live session)"))
                continue
            }
            // Build a per-op outcome string so a silent write failure is visible:
            // which of setPlayed / setResume succeeded, and the exact error if one
            // threw (a thrown target stays queued for the next drain). NOTE: a Plex
            // scrobble/watched-write returning 409 is swallowed as success by the
            // provider, so it shows OK here — that is correct, not a miss.
            var outcome = ""
            do {
                if let played = mutation.played {
                    try await applier.setPlayed(played, on: target, capturedAt: mutation.capturedAt)
                    outcome += "setPlayed(\(played))=OK "
                }
                if let resume = mutation.resumePosition {
                    try await applier.setResumePosition(resume, on: target, capturedAt: mutation.capturedAt)
                    outcome += "setResume(\(Int(resume)))=OK"
                    // Record the play's *real* time for this target so Home's Continue
                    // Watching overlay can clamp a server that stamps its own drain-time
                    // view timestamp (Plex) back down to it — otherwise an offline-drained
                    // resume re-floats a stale play to the top of the row. Only for a real
                    // in-progress position (`> 0`, not a finish/clear, which leaves the
                    // row anyway); keyed by target and kept newest-wins so a fresh play
                    // supersedes an older one.
                    if resume > 0, mutation.played != true {
                        let prior = state.appliedRecency[target.id]?.capturedAt ?? .distantPast
                        if mutation.capturedAt >= prior {
                            state.appliedRecency[target.id] = AppliedResumeRecord(
                                capturedAt: mutation.capturedAt,
                                appliedAt: now()
                            )
                        }
                    }
                } else if mutation.clearResume {
                    try await applier.setResumePosition(0, on: target, capturedAt: mutation.capturedAt)
                    outcome += "clearResume=OK"
                    // The in-progress position is gone (a finish clears resume
                    // everywhere), so drop any recency record guarding it.
                    state.appliedRecency[target.id] = nil
                }
                FanoutDiagnostics.emit(FanoutDiagnostics.drainTargetLine(
                    target,
                    outcome: outcome.isEmpty ? "noop(no state to write)" : outcome.trimmingCharacters(in: .whitespaces)))
            } catch {
                remaining.append(target)
                FanoutDiagnostics.emit(FanoutDiagnostics.drainTargetLine(
                    target,
                    outcome: outcome + "THROW(\(error)) -> requeued"))
            }
        }
        mutation.targets = remaining

        if mutation.traktPending, let intent = mutation.trakt {
            let key = mutation.traktIdempotencyKey(dayBucket: WatchMutation.dayBucket(for: mutation.capturedAt))
            if state.appliedTrakt[key] != nil {
                mutation.traktPending = false
                FanoutDiagnostics.emit("drain.trakt canonical=\(mutation.canonicalMediaID) -> skip(already applied this day)")
            } else {
                do {
                    try await applier.scrobbleTrakt(intent)
                    state.appliedTrakt[key] = now()
                    mutation.traktPending = false
                    FanoutDiagnostics.emit("drain.trakt canonical=\(mutation.canonicalMediaID) -> applied")
                } catch {
                    // keep pending; retry next drain
                    FanoutDiagnostics.emit("drain.trakt canonical=\(mutation.canonicalMediaID) -> THROW(\(error)) -> still pending")
                }
            }
        }

        // Simkl mirror (same idempotency pattern as Trakt).
        if mutation.simklPending, let intent = mutation.trakt {
            let key = mutation.traktIdempotencyKey(dayBucket: WatchMutation.dayBucket(for: mutation.capturedAt))
            if state.appliedSimkl[key] != nil {
                mutation.simklPending = false
                FanoutDiagnostics.emit("drain.simkl canonical=\(mutation.canonicalMediaID) -> skip(already applied this day)")
            } else {
                do {
                    try await applier.scrobbleSimkl(intent)
                    state.appliedSimkl[key] = now()
                    mutation.simklPending = false
                    FanoutDiagnostics.emit("drain.simkl canonical=\(mutation.canonicalMediaID) -> applied")
                } catch {
                    // keep pending; retry next drain
                    FanoutDiagnostics.emit("drain.simkl canonical=\(mutation.canonicalMediaID) -> THROW(\(error)) -> still pending")
                }
            }
        }

        // AniList mirror (anime only; the scrobbler no-ops for non-anime).
        if mutation.anilistPending, let intent = mutation.trakt {
            let key = mutation.traktIdempotencyKey(dayBucket: WatchMutation.dayBucket(for: mutation.capturedAt))
            if state.appliedAniList[key] != nil {
                mutation.anilistPending = false
                FanoutDiagnostics.emit("drain.anilist canonical=\(mutation.canonicalMediaID) -> skip(already applied this day)")
            } else {
                do {
                    try await applier.scrobbleAniList(intent)
                    state.appliedAniList[key] = now()
                    mutation.anilistPending = false
                    FanoutDiagnostics.emit("drain.anilist canonical=\(mutation.canonicalMediaID) -> applied")
                } catch {
                    // keep pending; retry next drain
                    FanoutDiagnostics.emit("drain.anilist canonical=\(mutation.canonicalMediaID) -> THROW(\(error)) -> still pending")
                }
            }
        }

        // MAL mirror (anime only; the scrobbler no-ops for non-anime).
        if mutation.malPending, let intent = mutation.trakt {
            let key = mutation.traktIdempotencyKey(dayBucket: WatchMutation.dayBucket(for: mutation.capturedAt))
            if state.appliedMAL[key] != nil {
                mutation.malPending = false
                FanoutDiagnostics.emit("drain.mal canonical=\(mutation.canonicalMediaID) -> skip(already applied this day)")
            } else {
                do {
                    try await applier.scrobbleMAL(intent)
                    state.appliedMAL[key] = now()
                    mutation.malPending = false
                    FanoutDiagnostics.emit("drain.mal canonical=\(mutation.canonicalMediaID) -> applied")
                } catch {
                    // keep pending; retry next drain
                    FanoutDiagnostics.emit("drain.mal canonical=\(mutation.canonicalMediaID) -> THROW(\(error)) -> still pending")
                }
            }
        }

        FanoutDiagnostics.emit(FanoutDiagnostics.drainDoneLine(
            canonicalMediaID: mutation.canonicalMediaID,
            remainingTargets: mutation.targets.count,
            fullyApplied: mutation.isFullyApplied,
            traktPending: mutation.traktPending,
            simklPending: mutation.simklPending,
            anilistPending: mutation.anilistPending,
            malPending: mutation.malPending))
    }

    // MARK: - Housekeeping

    private func pruneExpired() {
        let cutoffTrakt = now().addingTimeInterval(-traktTTL)
        state.appliedTrakt = state.appliedTrakt.filter { $0.value >= cutoffTrakt }
        state.appliedSimkl = state.appliedSimkl.filter { $0.value >= cutoffTrakt }
        state.appliedAniList = state.appliedAniList.filter { $0.value >= cutoffTrakt }
        state.appliedMAL = state.appliedMAL.filter { $0.value >= cutoffTrakt }
        let cutoffClock = now().addingTimeInterval(-clockTTL)
        // Keep clock entries that still guard a queued mutation regardless of age.
        let activeKeys = Set(state.pending.map(\.coalesceKey))
        state.clock = state.clock.filter { $0.value >= cutoffClock || activeKeys.contains($0.key) }
        // Resume-recency records are short-lived by design: prune by `appliedAt`
        // (device clock) so a stale record can never override a genuine later play.
        let cutoffRecency = now().addingTimeInterval(-resumeRecencyTTL)
        state.appliedRecency = state.appliedRecency.filter { $0.value.appliedAt >= cutoffRecency }
    }

    private func persist() {
        try? store.save(state)
    }
}
