import Foundation
import CoreModels
import MediaTransportCore

/// Per-account lifecycle aggregate, **confined to the `ShareCatalogCoordinator`
/// actor**. It owns all the mutable per-account catalog/scan/enrich/playback
/// lifecycle state that used to be spread across ~14 parallel coordinator
/// dictionaries keyed by `accountKey`.
///
/// This is a lifecycle aggregate, **not** a policy hub. It holds the per-account
/// components (store, pacer, arbiter, scanner, enrichers) and enforces the small
/// state invariants that were previously implicit across the coordinator's maps —
/// scan-task bookkeeping, the no-overwrite cancellation-reason ledger, scanner
/// generation currency, and the `active → invalidating → retired` phase that gates
/// playback admission. Provider ordering, scheduling fairness, NFO parsing,
/// persistence policy, and transport construction all remain in their existing
/// owners; the coordinator still drives every decision and only reaches into the
/// runtime for state.
///
/// Isolation contract: a runtime is only ever created, read, and mutated while the
/// coordinator actor is executing. It is a reference type so the coordinator can
/// mutate it in place, but it **never escapes that isolation** — the coordinator's
/// async scan/invalidation tasks and the scheduler's registered closures capture
/// only immutable ids and already-`Sendable` capabilities (the arbiter/enricher
/// actors, the account key, generation UUIDs), never the runtime itself. Results
/// always return through a coordinator method (`[weak coordinator]`).
final class ShareCatalogRuntime {
    /// Playback/removal race gate. A runtime is `active` for its whole normal life
    /// (including across credential rotations, which rebuild the scanner/enricher
    /// generation but keep the same store/pacer/arbiter). A **full** account
    /// invalidation flips it to `invalidating` *before* any cancel/drain so a racing
    /// `acquirePlayback` sees a non-live runtime and is rejected instead of reviving
    /// an arbiter for a torn-down account. The coordinator drops the runtime from its
    /// table once drained (`retired` is the absence of the runtime).
    enum Phase {
        case active
        case invalidating
    }

    // MARK: Stable identity (created once; survives credential rotation)

    let store: ShareCatalogStore
    let pacer: ShareScanPacer
    /// The per-account I/O arbiter. Created eagerly with the runtime so an arbiter
    /// exists **iff** a live runtime exists — this is what closes the lazy-create
    /// playback race: there is no code path that conjures an arbiter for an account
    /// without a runtime.
    let arbiter: MediaIOArbiter

    // MARK: Scanner/enricher generation (reset on credential rotation / replacement)

    var scanner: ShareScanner?
    var scannerID: UUID?
    var scannerRevision: CredentialRevision?
    var enricher: ShareEnricher?
    var localEnricher: ShareLocalMetadataEnricher?
    var artworkProbeWorker: ShareLocalArtworkProbeWorker?

    // MARK: Scan-task bookkeeping

    private(set) var scanTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var drainingScanTasks: [UUID: Task<Void, Never>] = [:]
    /// True while `rescan` is tearing down the prior pass before starting a fresh one,
    /// so `ensureScanning` doesn't spawn a competing walk in the gap.
    var restarting = false

    // MARK: Invalidation

    var invalidationTask: Task<Void, Never>?
    var invalidationID: UUID?

    // MARK: Diagnostics / coalescing

    /// The owner a coordinator-initiated cancellation stamps for an in-flight scan
    /// task before cancelling it. Consumed when the task ends so a non-completing scan
    /// is attributed to an exact, secret-safe owner (finding A5) rather than guessed.
    private var pendingCancellationReasons: [UUID: ShareScanCancellationOwner] = [:]
    /// When this share last completed a background (non-forced) scan, used by
    /// `ensureScanning` to coalesce per-render re-triggers.
    var lastBackgroundScanCompletedAt: Date?

    // MARK: Phase

    private(set) var phase: Phase = .active
    var isActive: Bool { phase == .active }

    init(store: ShareCatalogStore, pacer: ShareScanPacer, arbiter: MediaIOArbiter) {
        self.store = store
        self.pacer = pacer
        self.arbiter = arbiter
    }

    // MARK: - Lifecycle transitions

    /// Mark the runtime retiring. Called at the very start of a full invalidation,
    /// before any task cancellation or drain, so a concurrent playback request
    /// observes a non-live runtime.
    func beginInvalidating() { phase = .invalidating }

    /// Reset the scanner/enricher generation (credential rotation or invalidation).
    /// Keeps the stable store/pacer/arbiter identity intact.
    func resetGeneration() {
        scanner = nil
        scannerID = nil
        scannerRevision = nil
        lastBackgroundScanCompletedAt = nil
    }

    // MARK: - Scan-task bookkeeping (invariant: empty maps are dropped by the store table)

    func addScanTask(_ taskID: UUID, _ task: Task<Void, Never>) {
        scanTasks[taskID] = task
    }

    var hasActiveScanTasks: Bool { !scanTasks.isEmpty }

    /// Remove one finished active scan task and discard any reason stamped for it in
    /// the `recordScanOutcome`→`clearScanTask` window (the task is gone, so no future
    /// `recordScanOutcome` will ever consume it). taskIDs are unique, so this never
    /// changes any other task's attribution.
    func clearScanTask(_ taskID: UUID) {
        scanTasks[taskID] = nil
        _ = takeCancellationReason(taskID)
    }

    /// Take the current active scan tasks out (used by rescan/invalidation), leaving
    /// the active set empty.
    func takeActiveScanTasks() -> [UUID: Task<Void, Never>] {
        let taken = scanTasks
        scanTasks = [:]
        return taken
    }

    /// Move active scan tasks into the draining set (rescan: the old pass keeps
    /// draining while a fresh one starts).
    func moveActiveScanTasksToDraining() -> [UUID: Task<Void, Never>] {
        let taken = scanTasks
        scanTasks = [:]
        if !taken.isEmpty {
            drainingScanTasks.merge(taken, uniquingKeysWith: { current, _ in current })
        }
        return taken
    }

    /// Take the current draining scan tasks out (invalidation).
    func takeDrainingScanTasks() -> [UUID: Task<Void, Never>] {
        let taken = drainingScanTasks
        drainingScanTasks = [:]
        return taken
    }

    func clearDrainingScanTasks(_ taskIDs: Set<UUID>) {
        for taskID in taskIDs { drainingScanTasks[taskID] = nil }
    }

    // MARK: - Cancellation-reason ledger (no-overwrite; first decider owns it)

    func stampCancellationReasons<Keys: Sequence>(
        taskIDs: Keys?,
        owner: ShareScanCancellationOwner
    ) where Keys.Element == UUID {
        guard let taskIDs else { return }
        for taskID in taskIDs where pendingCancellationReasons[taskID] == nil {
            pendingCancellationReasons[taskID] = owner
        }
    }

    func takeCancellationReason(_ taskID: UUID) -> ShareScanCancellationOwner? {
        pendingCancellationReasons.removeValue(forKey: taskID)
    }

    var pendingCancellationReasonCount: Int { pendingCancellationReasons.count }

    // MARK: - Generation currency

    /// Whether a returning scan's captured generation is still the current one, so a
    /// superseded scanner/credential can't stamp its replacement's completion.
    func isGenerationCurrent(scannerID: UUID?, credentialRevision: CredentialRevision?) -> Bool {
        scannerID != nil
            && self.scannerID == scannerID
            && self.scannerRevision == credentialRevision
    }
}
