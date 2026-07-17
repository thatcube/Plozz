import Foundation
import CoreModels
import MediaTransportCore

public protocol ShareCatalogCoordinating: Sendable {
    /// Returns the read-only catalog capability for a share, creating the backing
    /// store/scanner/enricher on first use. The concrete store is never exposed —
    /// callers get only `any ShareCatalogReading`.
    func catalogReader(
        accountKey: String,
        displayName: String,
        credentialRevision: CredentialRevision,
        sessionFactory: @escaping ShareTransportSessionFactory
    ) async -> any ShareCatalogReading
    func rescan(accountKey: String) async
    func enrichItem(accountKey: String, itemID: String) async
    func noteInteractiveActivity(accountKey: String) async
}

/// App-owned cache and I/O coordinator for share catalogs, scanners, and
/// playback admission. `ShareProvider` is a value type SwiftUI rebuilds
/// constantly, so this state is injected from the composition root.
public actor ShareCatalogCoordinator: ShareCatalogCoordinating {
    public typealias ArbiterFactory = @Sendable (String) -> MediaIOArbiter

    private var stores: [String: ShareCatalogStore] = [:]
    private var scanners: [String: ShareScanner] = [:]
    private var scannerIDs: [String: UUID] = [:]
    private var scannerRevisions: [String: CredentialRevision] = [:]
    private var enrichers: [String: ShareEnricher] = [:]
    private var localEnrichers: [String: ShareLocalMetadataEnricher] = [:]
    private var pacers: [String: ShareScanPacer] = [:]
    private var scanTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private var drainingScanTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private var invalidationTasks: [String: Task<Void, Never>] = [:]
    private var invalidationTaskIDs: [String: UUID] = [:]
    private var restartingScans: Set<String> = []
    private var arbiters: [String: MediaIOArbiter] = [:]
    /// The owner a coordinator-initiated cancellation stamps for an in-flight scan
    /// task before cancelling it, keyed by account then task id. Consumed when the
    /// task ends so a non-completing scan can be attributed to an exact, secret-safe
    /// owner (finding A5) rather than guessed from timing.
    private var pendingCancellationReasons: [String: [UUID: ShareScanCancellationOwner]] = [:]
    private let metadataScheduler = ShareMetadataWorkScheduler()
    private var preferredAccountRevision: UInt64 = 0
    private let arbiterFactory: ArbiterFactory
    private let pipelineFactory: any ShareMetadataPipelineFactory
    /// When each share last completed a background (non-forced) scan.
    /// `catalog` is a computed property queried on every Home/browse access, and
    /// each access calls `ensureScanning`; without this, a share whose real walk
    /// finished (e.g. a small WebDAV root in ~20ms) would re-spawn a fresh no-op
    /// scan+enrich cycle on EVERY access — dozens per second while Home renders.
    /// Recording completion lets `ensureScanning` skip re-spawning within the
    /// coalesce window, moving the staleness throttle *before* the task machinery
    /// instead of inside the spawned task (`scanIfStale`), where it was too late.
    private var lastBackgroundScanCompletedAt: [String: Date] = [:]
    /// Minimum gap between background scan *spawns* for one share. Kept equal to
    /// `ShareScanner.scanIfStale`'s default `minInterval` so a spawn is only
    /// allowed once the walk would actually run — anything sooner is a guaranteed
    /// no-op. If the two ever drift, degradation is graceful: at worst one no-op
    /// spawn per window (never the per-render thrash, never a blocked needed scan
    /// as long as this stays ≤ the scanIfStale interval).
    private static let backgroundScanCoalesceInterval: TimeInterval = 600
    /// Where scan/enrich progress is reported for the Home banner + Settings.
    /// Wired once by the app (`AppState`); `.noop` until then (tests/previews).
    private var reporter: ShareScanReporter = .noop
    /// Secret-safe sink for scans that end without a completion stamp. Injected so
    /// tests can assert the exact owner/generation of each non-completing scan.
    private let diagnostics: ShareScanDiagnostics

    public init(
        arbiterFactory: @escaping ArbiterFactory = { MediaIOArbiter(accountID: $0) }
    ) {
        self.arbiterFactory = arbiterFactory
        self.diagnostics = DefaultShareScanDiagnostics()
        self.pipelineFactory = DefaultShareMetadataPipelineFactory(clients: .production)
    }

    init(
        arbiterFactory: @escaping ArbiterFactory = { MediaIOArbiter(accountID: $0) },
        diagnostics: ShareScanDiagnostics = DefaultShareScanDiagnostics(),
        pipelineFactory: any ShareMetadataPipelineFactory
    ) {
        self.arbiterFactory = arbiterFactory
        self.diagnostics = diagnostics
        self.pipelineFactory = pipelineFactory
    }

    /// Inject the app's scan-status reporter (call once at startup). Applies to
    /// future scanners/enrichers AND back-fills any already created before this
    /// ran (a startup race: the app configures the reporter from an async Task in
    /// its init, which can land after Home's first share query created a scanner
    /// with the `.noop` default — that left the banner + last-scanned line dead).
    public func configure(reporter: ShareScanReporter) async {
        self.reporter = reporter
        for scanner in scanners.values { await scanner.setReporter(reporter) }
        for enricher in enrichers.values { await enricher.setReporter(reporter) }
    }

    /// Gives the scheduler the current profile's media-share account ids. Their
    /// passive backlog drains before work retained for other profiles.
    public func setPreferredAccountKeys(
        _ accountKeys: Set<String>,
        revision: UInt64
    ) async {
        guard revision >= preferredAccountRevision else { return }
        preferredAccountRevision = revision
        await metadataScheduler.setPreferredAccountKeys(accountKeys)
    }

    /// Public capability seam: vends the read-only catalog for a share without
    /// exposing the concrete `ShareCatalogStore`. Delegates to the internal
    /// `store(...)` factory so registration/scan/enrich lifecycle is identical.
    public func catalogReader(
        accountKey: String,
        displayName: String,
        credentialRevision: CredentialRevision,
        sessionFactory: @escaping ShareTransportSessionFactory
    ) async -> any ShareCatalogReading {
        await store(
            accountKey: accountKey,
            displayName: displayName,
            credentialRevision: credentialRevision,
            sessionFactory: sessionFactory
        )
    }

    /// Return the shared catalog store for a share, creating it (and a dedicated
    /// scan transport session + scanner + enricher) on first use, and kicking a
    /// throttled background scan followed by enrichment. The scan browser is
    /// separate from the interactive one so a walk never starves live browsing.
    func store(
        accountKey: String,
        displayName: String,
        credentialRevision: CredentialRevision,
        sessionFactory: @escaping ShareTransportSessionFactory
    ) async -> ShareCatalogStore {
        while true {
            if let invalidationTask = invalidationTasks[accountKey] {
                await invalidationTask.value
                continue
            }
            let store = stores[accountKey] ?? {
                let created = ShareCatalogStore(accountKey: accountKey)
                stores[accountKey] = created
                return created
            }()
            let pacer = pacers[accountKey] ?? {
                let created = ShareScanPacer()
                pacers[accountKey] = created
                return created
            }()

            if let activeRevision = scannerRevisions[accountKey],
               activeRevision != credentialRevision {
                let staleLocalEnricher = localEnrichers.removeValue(forKey: accountKey)
                enrichers[accountKey] = nil
                await metadataScheduler.remove(accountKey: accountKey)
                await staleLocalEnricher?.close()
                await store.resetPendingLocalMetadataAttempts()
                await invalidateScanner(
                    accountKey: accountKey,
                    store: store,
                    releaseRuntimeState: false
                )
                continue
            }

            if scanners[accountKey] == nil {
                // Any prior instance with this deterministic account id has fully
                // invalidated above. Open the replacement status lifecycle before
                // its scanner can report, preserving ordered late-event fencing.
                reporter.shareRegistered(accountKey)
                // A factory of independent scan connections: the SMB library is serial
                // per connection, so parallelism comes from N separate transport sessions
                // (each its own socket), dedicated to scanning so a walk never starves
                // live browsing. The scanner builds `concurrency` of them per scan.
                let makeLister: @Sendable () -> ShareScanner.ScanLister = {
                    let browser = ShareTransportBrowser(
                        role: .scanner,
                        sessionFactory: sessionFactory
                    )
                    return ShareScanner.ScanLister(
                        list: { try await browser.listDirectory($0) },
                        close: { await browser.close() }
                    )
                }
                scanners[accountKey] = ShareScanner(
                    store: store, shareID: accountKey, name: displayName,
                    reporter: reporter, pacer: pacer, makeLister: makeLister
                )
                scannerIDs[accountKey] = UUID()
                scannerRevisions[accountKey] = credentialRevision
            }
            if enrichers[accountKey] == nil {
                // Pipeline construction is injected for deterministic lifecycle tests.
                // The production factory preserves the existing TVDB-when-configured,
                // keyless-otherwise selection and builds both workers.
                let pipeline = pipelineFactory.makePipeline(
                    store: store,
                    accountKey: accountKey,
                    reporter: reporter,
                    sessionFactory: sessionFactory
                )
                let enricher = pipeline.external
                enrichers[accountKey] = enricher
                // A dedicated `.metadata` transport session — separate from the
                // scanner's own pooled connections and from live browsing — reads
                // NFO sidecars. Owned alongside `enricher`; never touched from a
                // Home/grid/detail read (only scheduler slices + the urgent path).
                let localEnricher = pipeline.local
                localEnrichers[accountKey] = localEnricher
                let arbiter = arbiter(for: accountKey)
                await metadataScheduler.register(
                    accountKey: accountKey,
                    mayRun: { await arbiter.permitsBackgroundWork() },
                    runSlice: { maxItems, maxDuration in
                        await ShareMetadataWorkComposition.runSlice(
                            accountKey: accountKey,
                            maxItems: maxItems,
                            maxDuration: maxDuration,
                            local: localEnricher,
                            external: enricher
                        )
                    },
                    runItem: { itemID in
                        await ShareMetadataWorkComposition.runItem(
                            accountKey: accountKey,
                            itemID: itemID,
                            local: localEnricher,
                            external: enricher
                        )
                    },
                    pausePass: {
                        await enricher.pauseScheduledPass()
                    },
                    finishPass: {
                        await enricher.finishLogicalPass()
                    }
                )
            }
            await ensureScanning(accountKey)
            return store
        }
    }

    /// Force a fresh scan + enrichment of a share now (the Settings "Scan now"
    /// action). Unlike the auto path it ignores the staleness throttle. `scan()`
    /// and `enrichPending()` each self-guard against a concurrent run, so this is
    /// safe even if an auto-scan is already in flight. No-op only if the share was
    /// never registered (its scanner doesn't exist) — callers ensure it does by
    /// touching the provider's catalog first (see `ShareProvider.rescan()`).
    public func rescan(accountKey: String) async {
        while let invalidationTask = invalidationTasks[accountKey] {
            await invalidationTask.value
        }
        guard let scanner = scanners[accountKey],
              let scannerID = scannerIDs[accountKey],
              stores[accountKey] != nil else {
            return
        }
        restartingScans.insert(accountKey)
        let existingTaskEntries = scanTasks.removeValue(forKey: accountKey) ?? [:]
        if !existingTaskEntries.isEmpty {
            drainingScanTasks[accountKey, default: [:]].merge(
                existingTaskEntries,
                uniquingKeysWith: { current, _ in current }
            )
        }
        let existingTasks = Array(existingTaskEntries.values)
        stampCancellationReason(
            accountKey,
            taskIDs: existingTaskEntries.keys,
            owner: .rescanSuperseded
        )
        existingTasks.forEach { $0.cancel() }
        await stores[accountKey]?.invalidateScanGeneration()
        for task in existingTasks {
            await task.value
        }
        clearDrainingScanTasks(
            accountKey,
            taskIDs: Set(existingTaskEntries.keys)
        )
        guard scannerIDs[accountKey] == scannerID else {
            restartingScans.remove(accountKey)
            return
        }
        restartingScans.remove(accountKey)
        await startScan(accountKey: accountKey, scanner: scanner, force: true)
    }

    public func invalidate(accountKey: String) async {
        while true {
            if let invalidationTask = invalidationTasks[accountKey] {
                await invalidationTask.value
                continue
            }
            guard let store = stores[accountKey] else {
                reporter.shareRemoved(accountKey)
                return
            }
            await invalidateScanner(
                accountKey: accountKey,
                store: store,
                releaseRuntimeState: true
            )
            return
        }
    }

    public func acquirePlayback(accountKey: String) async throws -> MediaIOPlaybackLease {
        // Playback admission drains any active scanner to grant a lease; attribute that
        // cancellation to playback so the interrupted scan is diagnosable and not
        // mistaken for an unexplained cancellation.
        stampCancellationReason(
            accountKey,
            taskIDs: scanTasks[accountKey]?.keys,
            owner: .playbackAdmission
        )
        stampCancellationReason(
            accountKey,
            taskIDs: drainingScanTasks[accountKey]?.keys,
            owner: .playbackAdmission
        )
        await metadataScheduler.suspend(accountKey: accountKey)
        do {
            let lease = try await arbiter(for: accountKey).acquirePlayback()
            await metadataScheduler.resume(accountKey: accountKey)
            return lease
        } catch {
            await metadataScheduler.resume(accountKey: accountKey)
            throw error
        }
    }

    private func arbiter(for accountKey: String) -> MediaIOArbiter {
        if let arbiter = arbiters[accountKey] {
            return arbiter
        }
        let arbiter = arbiterFactory(accountKey)
        arbiters[accountKey] = arbiter
        return arbiter
    }

    // MARK: - Test introspection

    /// The number of per-account arbiters currently retained. Must return to zero
    /// across repeated add/invalidate cycles (finding A7). Test-only.
    func arbiterCount() -> Int {
        arbiters.count
    }

    /// When the given account last recorded a background-scan completion, or nil if a
    /// completing pass has not (yet) been stamped. Test-only assertion seam for the
    /// A5 completion-gating behavior.
    func backgroundScanCompletedAt(_ accountKey: String) -> Date? {
        lastBackgroundScanCompletedAt[accountKey]
    }

    /// The number of pending (stamped-but-unconsumed) cancellation reasons for an
    /// account. Must return to zero once every scan task has been cleared — a reason
    /// stamped in the `recordScanOutcome`→`clearScanTask` window must not leak. Test-only.
    func pendingCancellationReasonCount(_ accountKey: String) -> Int {
        pendingCancellationReasons[accountKey]?.count ?? 0
    }

    /// Test-only: stamp a cancellation reason for one task through the real
    /// no-overwrite stamp path (a racing playback/rescan does exactly this).
    func stampCancellationReasonForTesting(
        _ accountKey: String,
        taskID: UUID,
        owner: ShareScanCancellationOwner
    ) {
        let entry: [UUID: Task<Void, Never>] = [taskID: Task {}]
        stampCancellationReason(accountKey, taskIDs: entry.keys, owner: owner)
    }

    /// Test-only: consume a task's reason exactly as `recordScanOutcome` does.
    @discardableResult
    func takeCancellationReasonForTesting(
        _ accountKey: String,
        taskID: UUID
    ) -> ShareScanCancellationOwner? {
        takeCancellationReason(accountKey, taskID: taskID)
    }

    /// Test-only: run the real `clearScanTask`, which must discard any reason stamped
    /// after `recordScanOutcome` already consumed the task's first reason.
    func clearScanTaskForTesting(_ accountKey: String, taskID: UUID) {
        clearScanTask(accountKey, taskID: taskID)
    }

    /// Fast-track enrichment of ONE item the user just opened, ahead of the
    /// background backlog, so its hero/poster/overview persist promptly (and the
    /// persisted art then supersedes the flaky live title-only fallback). Spawns a
    /// background task and returns immediately — callers on the detail hot path add
    /// no latency. No-op if the share was never registered or the item is already
    /// enriched.
    public func enrichItem(accountKey: String, itemID: String) async {
        guard enrichers[accountKey] != nil else { return }
        await metadataScheduler.enqueueItem(accountKey: accountKey, itemID: itemID)
    }

    public func noteInteractiveActivity(accountKey: String) async {
        let pacer = pacers[accountKey] ?? {
            let created = ShareScanPacer()
            pacers[accountKey] = created
            return created
        }()
        await pacer.noteInteractiveActivity()
        await metadataScheduler.noteInteractiveActivity(accountKey: accountKey)
    }

    /// Spawn a throttled scan attempt (then enqueue passive enrichment) unless one is
    /// already in flight for this share, or one completed within the coalesce
    /// window. `catalog` is queried on every Home/browse access, so without the
    /// completion cooldown a share whose walk already finished would re-spawn a
    /// no-op scan+enrich on every access. `ShareScanner.scanIfStale` still
    /// governs whether the actual walk runs when a spawn IS allowed.
    private func ensureScanning(_ accountKey: String) async {
        guard scanTasks[accountKey]?.isEmpty != false,
              !restartingScans.contains(accountKey),
              let scanner = scanners[accountKey] else { return }
        if let completedAt = lastBackgroundScanCompletedAt[accountKey],
           Date().timeIntervalSince(completedAt) < Self.backgroundScanCoalesceInterval {
            return
        }
        await startScan(accountKey: accountKey, scanner: scanner, force: false)
    }

    private func startScan(
        accountKey: String,
        scanner: ShareScanner,
        force: Bool
    ) async {
        guard enrichers[accountKey] != nil,
              let store = stores[accountKey] else { return }
        // Capture the scanner/credential generation this walk is bound to, so
        // completion is only stamped if the SAME generation is still current when the
        // walk returns (a superseded scanner/credential must not stamp its replacement).
        let scannerID = scannerIDs[accountKey]
        let credentialRevision = scannerRevisions[accountKey]
        await metadataScheduler.suspend(accountKey: accountKey)
        let resource = ShareScannerResource(scanner: scanner, store: store)
        let scannerLease: MediaIOScannerLease
        do {
            scannerLease = try await arbiter(for: accountKey).acquireScanner(resource: resource)
        } catch {
            await metadataScheduler.resume(accountKey: accountKey)
            return
        }
        await metadataScheduler.resume(accountKey: accountKey)
        let taskID = UUID()
        let startGate = ShareScanStartGate()
        let task = Task(priority: .utility) { [weak self] in
            await startGate.wait()
            guard !Task.isCancelled else {
                resource.markDrained()
                await scannerLease.finishAndWait()
                await self?.recordScanOutcome(
                    accountKey,
                    taskID: taskID,
                    scannerID: scannerID,
                    credentialRevision: credentialRevision,
                    outcome: .cancelled(scanGeneration: nil),
                    taskCancelled: true
                )
                await self?.clearScanTask(accountKey, taskID: taskID)
                return
            }
            ShareBackgroundActivity.scanStarted()
            BrowseDiagnostics.event("scan+ \(accountKey) force=\(force)")
            let outcome: ShareScanOutcome
            if force {
                outcome = await scanner.scan()
            } else {
                outcome = await scanner.scanIfStale()
            }
            ShareBackgroundActivity.scanFinished()
            BrowseDiagnostics.event("scan- \(accountKey)")
            resource.markDrained()
            await scannerLease.finishAndWait()
            if !Task.isCancelled {
                await self?.metadataScheduler.enqueueBacklog(accountKey: accountKey)
            }
            // Record scan completion so `ensureScanning` coalesces the frequent
            // per-render re-triggers into at most one cycle per window — but ONLY when
            // this pass genuinely completed for the still-current generation and was
            // not cancelled. A cancelled/superseded/invalidated pass records a
            // secret-safe non-completion diagnostic instead and never suppresses the
            // next needed scan (finding A5). A forced "Scan now" that completes also
            // resets the timestamp so it doesn't immediately re-thrash on Home render.
            await self?.recordScanOutcome(
                accountKey,
                taskID: taskID,
                scannerID: scannerID,
                credentialRevision: credentialRevision,
                outcome: outcome,
                taskCancelled: Task.isCancelled
            )
            await self?.clearScanTask(accountKey, taskID: taskID)
        }
        resource.attach(task)
        scanTasks[accountKey, default: [:]][taskID] = task
        await startGate.open()
    }

    private func clearScanTask(_ accountKey: String, taskID: UUID) {
        scanTasks[accountKey]?[taskID] = nil
        if scanTasks[accountKey]?.isEmpty == true {
            scanTasks[accountKey] = nil
        }
        // Discard any reason stamped for this task in the window between
        // `recordScanOutcome` consuming its first reason and this removal. The task is
        // finished, so no future `recordScanOutcome` will ever consume a reason keyed to
        // this taskID; leaving it would leak into `pendingCancellationReasons`. taskIDs
        // are unique UUIDs, so this never changes attribution of any other task.
        _ = takeCancellationReason(accountKey, taskID: taskID)
    }

    /// Decide whether a finished scan pass earns a background-completion timestamp,
    /// and record a secret-safe non-completion diagnostic otherwise (finding A5).
    ///
    /// A completion stamp — which suppresses the next needed scan for the coalesce
    /// window — is recorded ONLY when the pass genuinely completed (or was a true
    /// no-op), the task was not cancelled, AND the scanner/credential generation this
    /// walk was bound to is still current. Everything else (cancelled, invalidated,
    /// superseded, failed-to-start) records an owner-attributed diagnostic and leaves
    /// completion unset so the next access rescans.
    private func recordScanOutcome(
        _ accountKey: String,
        taskID: UUID,
        scannerID: UUID?,
        credentialRevision: CredentialRevision?,
        outcome: ShareScanOutcome,
        taskCancelled: Bool
    ) {
        let reason = takeCancellationReason(accountKey, taskID: taskID)
        let generationCurrent = scannerID != nil
            && scannerIDs[accountKey] == scannerID
            && scannerRevisions[accountKey] == credentialRevision
        if outcome.earnsCompletionStamp && !taskCancelled && generationCurrent {
            lastBackgroundScanCompletedAt[accountKey] = Date()
            return
        }
        let owner = cancellationOwner(
            reason: reason,
            outcome: outcome,
            generationCurrent: generationCurrent
        )
        diagnostics.recordCancellation(
            ShareScanCancellationRecord(
                accountKey: accountKey,
                owner: owner,
                scannerGeneration: scannerID,
                credentialRevision: credentialRevision?.rawValue,
                outcome: outcome.diagnosticLabel
            )
        )
    }

    /// Resolve the authoritative owner of a non-completing scan. A coordinator-stamped
    /// reason (rescan/credential/invalidation/playback) is authoritative; otherwise the
    /// outcome and generation currency disambiguate a supersession from an unattributed
    /// teardown-timing cancellation. Timing is never consulted.
    private func cancellationOwner(
        reason: ShareScanCancellationOwner?,
        outcome: ShareScanOutcome,
        generationCurrent: Bool
    ) -> ShareScanCancellationOwner {
        if let reason { return reason }
        switch outcome {
        case .invalidated, .failedToStart:
            return .scannerGenerationReplaced
        case .completedClean, .completedPartial, .freshNoOp:
            // A genuinely completed pass that did not stamp can only mean its
            // generation was superseded while it ran.
            return .supersededCompletion
        case .cancelled:
            return generationCurrent ? .unattributed : .scannerGenerationReplaced
        }
    }

    private func stampCancellationReason(
        _ accountKey: String,
        taskIDs: Dictionary<UUID, Task<Void, Never>>.Keys?,
        owner: ShareScanCancellationOwner
    ) {
        guard let taskIDs, !taskIDs.isEmpty else { return }
        for taskID in taskIDs {
            // Never overwrite a reason already stamped by an earlier owner for the same
            // task; the first coordinator action that decides to cancel it owns it.
            if pendingCancellationReasons[accountKey]?[taskID] == nil {
                pendingCancellationReasons[accountKey, default: [:]][taskID] = owner
            }
        }
    }

    private func takeCancellationReason(
        _ accountKey: String,
        taskID: UUID
    ) -> ShareScanCancellationOwner? {
        let reason = pendingCancellationReasons[accountKey]?.removeValue(forKey: taskID)
        if pendingCancellationReasons[accountKey]?.isEmpty == true {
            pendingCancellationReasons[accountKey] = nil
        }
        return reason
    }

    private func clearDrainingScanTasks(
        _ accountKey: String,
        taskIDs: Set<UUID>
    ) {
        for taskID in taskIDs {
            drainingScanTasks[accountKey]?[taskID] = nil
        }
        if drainingScanTasks[accountKey]?.isEmpty == true {
            drainingScanTasks[accountKey] = nil
        }
    }

    private func invalidateScanner(
        accountKey: String,
        store: ShareCatalogStore,
        releaseRuntimeState: Bool
    ) async {
        let scanner = scanners.removeValue(forKey: accountKey)
        scannerIDs[accountKey] = nil
        scannerRevisions[accountKey] = nil
        lastBackgroundScanCompletedAt[accountKey] = nil
        let activeTasks = scanTasks.removeValue(forKey: accountKey) ?? [:]
        let drainingTasks = drainingScanTasks.removeValue(forKey: accountKey) ?? [:]
        let taskEntries = activeTasks.merging(
            drainingTasks,
            uniquingKeysWith: { current, _ in current }
        )
        // Attribute the cancellation before cancelling: a full invalidation is an
        // account removal; a runtime-preserving one is a credential rotation.
        stampCancellationReason(
            accountKey,
            taskIDs: taskEntries.keys,
            owner: releaseRuntimeState ? .accountInvalidation : .credentialChange
        )
        let tasks = Array(taskEntries.values)
        tasks.forEach { $0.cancel() }
        let invalidationID = UUID()
        let invalidationTask = Task { [weak self] in
            await scanner?.invalidate()
            await store.invalidateScanGeneration()
            for task in tasks {
                await task.value
            }
            await self?.finishInvalidation(
                accountKey: accountKey,
                invalidationID: invalidationID,
                releaseRuntimeState: releaseRuntimeState
            )
        }
        invalidationTasks[accountKey] = invalidationTask
        invalidationTaskIDs[accountKey] = invalidationID
        await invalidationTask.value
    }

    private func finishInvalidation(
        accountKey: String,
        invalidationID: UUID,
        releaseRuntimeState: Bool
    ) async {
        guard invalidationTaskIDs[accountKey] == invalidationID else { return }
        if releaseRuntimeState {
            let lateScanner = scanners.removeValue(forKey: accountKey)
            scannerIDs[accountKey] = nil
            scannerRevisions[accountKey] = nil
            let lateActiveTasks = scanTasks.removeValue(forKey: accountKey) ?? [:]
            let lateDrainingTasks = drainingScanTasks.removeValue(forKey: accountKey) ?? [:]
            let lateTasks = Array(lateActiveTasks.merging(
                lateDrainingTasks,
                uniquingKeysWith: { current, _ in current }
            ).values)
            lateTasks.forEach { $0.cancel() }
            await lateScanner?.invalidate()
            await stores[accountKey]?.invalidateScanGeneration()
            for task in lateTasks {
                await task.value
            }
            stores[accountKey] = nil
            enrichers[accountKey] = nil
            let removedLocalEnricher = localEnrichers.removeValue(forKey: accountKey)
            pacers[accountKey] = nil
            await metadataScheduler.remove(accountKey: accountKey)
            await removedLocalEnricher?.close()
            reporter.shareRemoved(accountKey)
            pendingCancellationReasons[accountKey] = nil
            // Retire the per-account arbiter (finding A7): reject new admission, drain
            // any active scanner under the bounded deadline, and wait for already-issued
            // playback leases to drain naturally. Remove it only after it drains, and
            // only if the dictionary still points at THIS identity — a re-add after this
            // completed invalidation installs a fresh arbiter generation that must
            // survive. This awaits genuine playback lifetime but never a hung scanner.
            if let arbiter = arbiters[accountKey] {
                await arbiter.shutdownAndDrain()
                if arbiters[accountKey] === arbiter {
                    arbiters[accountKey] = nil
                }
            }
        }
        restartingScans.remove(accountKey)
        invalidationTasks[accountKey] = nil
        invalidationTaskIDs[accountKey] = nil
    }
}

private actor ShareScanStartGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// The graceful-cancel-side dependency a scanner resource notifies so a superseded
/// scan generation can no longer commit writes. Extracted as a narrow seam so a
/// blocked implementation cannot prevent force-close from reaching lister closure,
/// and so tests can inject a blocking invalidator. `ShareCatalogStore` conforms.
protocol ScanGenerationInvalidating: Sendable {
    func invalidateScanGeneration() async
}

/// The force-close-side dependency a scanner resource drives to tear down active
/// directory listers (each a live transport session) immediately, independent of
/// the graceful-cancel path. `ShareScanner` conforms.
protocol ScanListerForceClosing: Sendable {
    func forceCloseActiveListers() async
}

extension ShareCatalogStore: ScanGenerationInvalidating {}
extension ShareScanner: ScanListerForceClosing {}

final class ShareScannerResource: MediaIOScannerResource, @unchecked Sendable {
    private let listerCloser: ScanListerForceClosing
    private let generationInvalidator: ScanGenerationInvalidating
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var drained = false

    init(scanner: ScanListerForceClosing, store: ScanGenerationInvalidating) {
        self.listerCloser = scanner
        self.generationInvalidator = store
    }

    var isDrained: Bool {
        lock.withLock { drained }
    }

    func attach(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            self.task = task
            return cancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func markDrained() {
        lock.withLock {
            drained = true
            task = nil
        }
    }

    /// Synchronously mark the resource cancelled and cancel the in-flight scan task.
    /// Contains no `await`, so it can never inherit a blocked graceful-cancel
    /// dependency; both `cancel()` and `forceClose()` start here. Idempotent:
    /// re-marking and re-cancelling an already-cancelled task are no-ops.
    private func cancelTaskSynchronously() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    func cancel() async {
        cancelTaskSynchronously()
        await generationInvalidator.invalidateScanGeneration()
    }

    func forceClose() async throws {
        // Do NOT await cancel() first. If the graceful-cancel dependency
        // (generation invalidation) is blocked/hung, awaiting it here would repeat
        // the same blockage and force-close would never reach active lister closure.
        // Instead: cancel the scan task synchronously, tear down active listers
        // immediately (this is what actually stops in-flight transport I/O), mark
        // drained, then perform generation-invalidation bookkeeping last.
        cancelTaskSynchronously()
        await listerCloser.forceCloseActiveListers()
        lock.withLock { drained = true }
        await generationInvalidator.invalidateScanGeneration()
    }
}
