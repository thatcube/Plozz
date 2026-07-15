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

    /// One lifecycle aggregate per media-share account, replacing the ~14 parallel
    /// `[accountKey: ...]` dictionaries this coordinator used to hold. The coordinator
    /// still owns every decision (registration, scan spawning, scheduling, teardown);
    /// it just reaches into the account's `ShareCatalogRuntime` for that account's
    /// mutable state instead of correlating a dozen separate maps.
    ///
    /// Isolation: runtimes are created/read/mutated only while this actor runs and
    /// never escape it. Async scan/invalidation tasks and the scheduler's registered
    /// closures capture only immutable ids and `Sendable` sub-capabilities (arbiter,
    /// enrichers, account key, generation UUIDs) and always report back through a
    /// coordinator method — never the runtime instance.
    private var runtimes: [String: ShareCatalogRuntime] = [:]
    private let metadataScheduler = ShareMetadataWorkScheduler()
    private var preferredAccountRevision: UInt64 = 0
    private let arbiterFactory: ArbiterFactory
    private let pipelineFactory: any ShareMetadataPipelineFactory
    private let artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle
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
        self.artworkCacheLifecycle = NoopShareLocalArtworkCacheLifecycle()
    }

    public init(
        arbiterFactory: @escaping ArbiterFactory = { MediaIOArbiter(accountID: $0) },
        artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle
    ) {
        self.arbiterFactory = arbiterFactory
        self.diagnostics = DefaultShareScanDiagnostics()
        self.pipelineFactory = DefaultShareMetadataPipelineFactory(clients: .production)
        self.artworkCacheLifecycle = artworkCacheLifecycle
    }

    init(
        arbiterFactory: @escaping ArbiterFactory = { MediaIOArbiter(accountID: $0) },
        diagnostics: ShareScanDiagnostics = DefaultShareScanDiagnostics(),
        pipelineFactory: any ShareMetadataPipelineFactory,
        artworkCacheLifecycle: any ShareLocalArtworkCacheLifecycle =
            NoopShareLocalArtworkCacheLifecycle()
    ) {
        self.arbiterFactory = arbiterFactory
        self.diagnostics = diagnostics
        self.pipelineFactory = pipelineFactory
        self.artworkCacheLifecycle = artworkCacheLifecycle
    }

    /// Inject the app's scan-status reporter (call once at startup). Applies to
    /// future scanners/enrichers AND back-fills any already created before this
    /// ran (a startup race: the app configures the reporter from an async Task in
    /// its init, which can land after Home's first share query created a scanner
    /// with the `.noop` default — that left the banner + last-scanned line dead).
    public func configure(reporter: ShareScanReporter) async {
        self.reporter = reporter
        for runtime in runtimes.values {
            if let scanner = runtime.scanner { await scanner.setReporter(reporter) }
            if let enricher = runtime.enricher { await enricher.setReporter(reporter) }
        }
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
        await artworkCacheLifecycle.setPreferredAccountKeys(accountKeys, revision: revision)
    }

    /// Removes one display-rejected local artwork fingerprint from future catalog
    /// projections. The reference is never logged and is accepted only by its owning
    /// account runtime.
    public func rejectArtwork(
        accountKey: String,
        reference: NetworkArtworkReference
    ) async {
        guard reference.accountID == accountKey,
              let store = runtimes[accountKey]?.store else { return }
        await store.rejectArtworkReference(reference)
    }

    /// Resolves a portable opaque artwork identity through the live account-local
    /// catalog. No path leaves ProviderShare except inside the transport locator.
    public func artworkLocator(
        for reference: NetworkArtworkReference
    ) async -> NetworkFileLocator? {
        guard let runtime = runtimes[reference.accountID],
              runtime.isActive,
              runtime.invalidationTask == nil else { return nil }
        return await runtime.store.artworkLocator(for: reference)
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

    /// Existing committed catalog only. Unlike `store(...)`, this never creates
    /// scanner/enricher state, starts a scan, or acquires a transport lease.
    func existingStore(accountKey: String) -> ShareCatalogStore? {
        stores[accountKey]
    }

    /// Test seam for a pre-populated committed catalog. Production creates stores
    /// only through `store(...)`.
    func registerExistingStore(_ store: ShareCatalogStore, accountKey: String) {
        stores[accountKey] = store
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
            if let invalidationTask = runtimes[accountKey]?.invalidationTask {
                await invalidationTask.value
                continue
            }
            let runtime = runtimes[accountKey] ?? {
                let created = ShareCatalogRuntime(
                    store: ShareCatalogStore(accountKey: accountKey),
                    pacer: ShareScanPacer(),
                    arbiter: arbiterFactory(accountKey)
                )
                runtimes[accountKey] = created
                return created
            }()
            let store = runtime.store
            await store.configureArtworkReferenceContext(
                accountID: accountKey,
                credentialRevision: credentialRevision
            )

            if let activeRevision = runtime.scannerRevision,
               activeRevision != credentialRevision {
                let staleLocalEnricher = runtime.localEnricher
                let staleArtworkProbeWorker = runtime.artworkProbeWorker
                runtime.localEnricher = nil
                runtime.artworkProbeWorker = nil
                runtime.enricher = nil
                await metadataScheduler.remove(accountKey: accountKey)
                await staleLocalEnricher?.close()
                await staleArtworkProbeWorker?.close()
                await store.resetPendingLocalMetadataAttempts()
                await store.resetArtworkProbeTransientFailures()
                await invalidateScanner(
                    accountKey: accountKey,
                    runtime: runtime,
                    releaseRuntimeState: false
                )
                continue
            }

            if runtime.scanner == nil {
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
                runtime.scanner = ShareScanner(
                    store: store, shareID: accountKey, name: displayName,
                    reporter: reporter, pacer: runtime.pacer, makeLister: makeLister
                )
                runtime.scannerID = UUID()
                runtime.scannerRevision = credentialRevision
            }
            if runtime.enricher == nil {
                // Pipeline construction is injected for deterministic lifecycle tests.
                // The production factory preserves the existing TVDB-when-configured,
                // keyless-otherwise selection and builds both workers.
                let pipeline = pipelineFactory.makePipeline(
                    store: store,
                    accountKey: accountKey,
                    credentialRevision: credentialRevision,
                    reporter: reporter,
                    sessionFactory: sessionFactory
                )
                let enricher = pipeline.external
                runtime.enricher = enricher
                // A dedicated `.metadata` transport session — separate from the
                // scanner's own pooled connections and from live browsing — reads
                // NFO sidecars. Owned alongside `enricher`; never touched from a
                // Home/grid/detail read (only scheduler slices + the urgent path).
                let localEnricher = pipeline.local
                runtime.localEnricher = localEnricher
                let artworkProbeWorker = pipeline.artwork
                runtime.artworkProbeWorker = artworkProbeWorker
                // Bind the account's Sendable sub-capabilities into the scheduler
                // closures; the runtime itself is never captured.
                let arbiter = runtime.arbiter
                await metadataScheduler.register(
                    accountKey: accountKey,
                    mayRun: { await arbiter.permitsBackgroundWork() },
                    runSlice: { maxItems, maxDuration in
                        await ShareMetadataWorkComposition.runSlice(
                            accountKey: accountKey,
                            maxItems: maxItems,
                            maxDuration: maxDuration,
                            local: localEnricher,
                            artwork: artworkProbeWorker,
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
        while let invalidationTask = runtimes[accountKey]?.invalidationTask {
            await invalidationTask.value
        }
        guard let runtime = runtimes[accountKey],
              let scanner = runtime.scanner,
              let scannerID = runtime.scannerID else {
            return
        }
        runtime.restarting = true
        let existingTaskEntries = runtime.moveActiveScanTasksToDraining()
        let existingTasks = Array(existingTaskEntries.values)
        runtime.stampCancellationReasons(
            taskIDs: existingTaskEntries.keys,
            owner: .rescanSuperseded
        )
        existingTasks.forEach { $0.cancel() }
        await runtime.store.invalidateScanGeneration()
        for task in existingTasks {
            await task.value
        }
        runtime.clearDrainingScanTasks(Set(existingTaskEntries.keys))
        guard runtime.scannerID == scannerID else {
            runtime.restarting = false
            return
        }
        runtime.restarting = false
        await startScan(accountKey: accountKey, runtime: runtime, scanner: scanner, force: true)
    }

    public func invalidate(accountKey: String) async {
        while true {
            if let invalidationTask = runtimes[accountKey]?.invalidationTask {
                await invalidationTask.value
                continue
            }
            guard let runtime = runtimes[accountKey] else {
                reporter.shareRemoved(accountKey)
                return
            }
            await invalidateScanner(
                accountKey: accountKey,
                runtime: runtime,
                releaseRuntimeState: true
            )
            return
        }
    }

    public func acquirePlayback(accountKey: String) async throws -> MediaIOPlaybackLease {
        // Look up a LIVE runtime; never lazily create one for an absent, invalidating,
        // or retired account. A playback request that lost the race to account removal
        // fails bounded here rather than conjuring and retaining a fresh arbiter for a
        // torn-down account (the disclosed A7 follow-up race). An already-issued lease
        // that is still alive keeps draining independently through its own arbiter.
        guard let runtime = runtimes[accountKey], runtime.isActive else {
            throw MediaTransportError.resourceBusy
        }
        let arbiter = runtime.arbiter
        // Playback admission drains any active scanner to grant a lease; attribute that
        // cancellation to playback so the interrupted scan is diagnosable and not
        // mistaken for an unexplained cancellation.
        runtime.stampCancellationReasons(
            taskIDs: runtime.scanTasks.keys,
            owner: .playbackAdmission
        )
        runtime.stampCancellationReasons(
            taskIDs: runtime.drainingScanTasks.keys,
            owner: .playbackAdmission
        )
        await metadataScheduler.suspend(accountKey: accountKey)
        do {
            let lease = try await arbiter.acquirePlayback()
            await metadataScheduler.resume(accountKey: accountKey)
            return lease
        } catch {
            await metadataScheduler.resume(accountKey: accountKey)
            throw error
        }
    }

    // MARK: - Test introspection

    /// The number of live per-account runtimes (each owning exactly one arbiter)
    /// currently retained. Must return to zero across repeated add/invalidate cycles
    /// (finding A7). Test-only.
    func arbiterCount() -> Int {
        runtimes.count
    }

    /// When the given account last recorded a background-scan completion, or nil if a
    /// completing pass has not (yet) been stamped. Test-only assertion seam for the
    /// A5 completion-gating behavior.
    func backgroundScanCompletedAt(_ accountKey: String) -> Date? {
        runtimes[accountKey]?.lastBackgroundScanCompletedAt
    }

    /// The number of pending (stamped-but-unconsumed) cancellation reasons for an
    /// account. Must return to zero once every scan task has been cleared — a reason
    /// stamped in the `recordScanOutcome`→`clearScanTask` window must not leak. Test-only.
    func pendingCancellationReasonCount(_ accountKey: String) -> Int {
        runtimes[accountKey]?.pendingCancellationReasonCount ?? 0
    }

    /// Test-only: stamp a cancellation reason for one task through the real
    /// no-overwrite stamp path (a racing playback/rescan does exactly this). Creates a
    /// runtime shell for the account if one does not exist yet — a TEST-ONLY seam that
    /// does not exist on any production path (production never conjures a runtime here).
    func stampCancellationReasonForTesting(
        _ accountKey: String,
        taskID: UUID,
        owner: ShareScanCancellationOwner
    ) {
        let runtime = runtimes[accountKey] ?? {
            let created = ShareCatalogRuntime(
                store: ShareCatalogStore(accountKey: accountKey),
                pacer: ShareScanPacer(),
                arbiter: arbiterFactory(accountKey)
            )
            runtimes[accountKey] = created
            return created
        }()
        let entry: [UUID: Task<Void, Never>] = [taskID: Task {}]
        runtime.stampCancellationReasons(taskIDs: entry.keys, owner: owner)
    }

    /// Test-only: consume a task's reason exactly as `recordScanOutcome` does.
    @discardableResult
    func takeCancellationReasonForTesting(
        _ accountKey: String,
        taskID: UUID
    ) -> ShareScanCancellationOwner? {
        runtimes[accountKey]?.takeCancellationReason(taskID)
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
        guard runtimes[accountKey]?.enricher != nil else { return }
        await metadataScheduler.enqueueItem(accountKey: accountKey, itemID: itemID)
    }

    public func noteInteractiveActivity(accountKey: String) async {
        // Note interactive activity on the account's pacer when it is registered.
        // An unregistered account has no scanner/pacer to pace, so there is nothing
        // to note locally — and we never lazily create a runtime here (that would
        // install an arbiter for an account with no store). The global scheduler
        // activity signal is always delivered.
        if let pacer = runtimes[accountKey]?.pacer {
            await pacer.noteInteractiveActivity()
        }
        await metadataScheduler.noteInteractiveActivity(accountKey: accountKey)
    }

    /// Spawn a throttled scan attempt (then enqueue passive enrichment) unless one is
    /// already in flight for this share, or one completed within the coalesce
    /// window. `catalog` is queried on every Home/browse access, so without the
    /// completion cooldown a share whose walk already finished would re-spawn a
    /// no-op scan+enrich on every access. `ShareScanner.scanIfStale` still
    /// governs whether the actual walk runs when a spawn IS allowed.
    private func ensureScanning(_ accountKey: String) async {
        guard let runtime = runtimes[accountKey],
              !runtime.hasActiveScanTasks,
              !runtime.restarting,
              let scanner = runtime.scanner else { return }
        if let completedAt = runtime.lastBackgroundScanCompletedAt,
           Date().timeIntervalSince(completedAt) < Self.backgroundScanCoalesceInterval {
            return
        }
        await startScan(accountKey: accountKey, runtime: runtime, scanner: scanner, force: false)
    }

    private func startScan(
        accountKey: String,
        runtime: ShareCatalogRuntime,
        scanner: ShareScanner,
        force: Bool
    ) async {
        guard runtime.enricher != nil else { return }
        let store = runtime.store
        // Capture the scanner/credential generation this walk is bound to, so
        // completion is only stamped if the SAME generation is still current when the
        // walk returns (a superseded scanner/credential must not stamp its replacement).
        let scannerID = runtime.scannerID
        let credentialRevision = runtime.scannerRevision
        await metadataScheduler.suspend(accountKey: accountKey)
        let resource = ShareScannerResource(scanner: scanner, store: store)
        let scannerLease: MediaIOScannerLease
        do {
            scannerLease = try await runtime.arbiter.acquireScanner(resource: resource)
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
        runtime.addScanTask(taskID, task)
        await startGate.open()
    }

    private func clearScanTask(_ accountKey: String, taskID: UUID) {
        // The runtime discards the task entry AND any reason stamped for it in the
        // window between `recordScanOutcome` consuming its first reason and this
        // removal. taskIDs are unique UUIDs, so this never changes attribution of any
        // other task. If the runtime was already removed by a full invalidation this
        // is a no-op (that path awaits every task before removal, so this normally runs
        // while the runtime is still present).
        runtimes[accountKey]?.clearScanTask(taskID)
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
        // The runtime is present here on every real path: a full invalidation awaits
        // each scan task (which calls this) before removing the runtime, and a
        // credential rotation preserves it. If it is somehow absent there is no
        // generation/reason to reconcile, so there is nothing to record.
        guard let runtime = runtimes[accountKey] else { return }
        let reason = runtime.takeCancellationReason(taskID)
        let generationCurrent = runtime.isGenerationCurrent(
            scannerID: scannerID,
            credentialRevision: credentialRevision
        )
        if outcome.earnsCompletionStamp && !taskCancelled && generationCurrent {
            runtime.lastBackgroundScanCompletedAt = Date()
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

    private func invalidateScanner(
        accountKey: String,
        runtime: ShareCatalogRuntime,
        releaseRuntimeState: Bool
    ) async {
        // A full account invalidation marks the runtime retiring BEFORE any cancel or
        // drain, so a concurrent `acquirePlayback` observes a non-live runtime and is
        // rejected instead of reviving the arbiter. A credential rotation keeps the
        // runtime active (same store/arbiter identity, new scanner/enricher generation).
        if releaseRuntimeState { runtime.beginInvalidating() }
        let scanner = runtime.scanner
        runtime.resetGeneration()
        let activeTasks = runtime.takeActiveScanTasks()
        let drainingTasks = runtime.takeDrainingScanTasks()
        let taskEntries = activeTasks.merging(
            drainingTasks,
            uniquingKeysWith: { current, _ in current }
        )
        // Attribute the cancellation before cancelling: a full invalidation is an
        // account removal; a runtime-preserving one is a credential rotation.
        runtime.stampCancellationReasons(
            taskIDs: taskEntries.keys,
            owner: releaseRuntimeState ? .accountInvalidation : .credentialChange
        )
        let tasks = Array(taskEntries.values)
        tasks.forEach { $0.cancel() }
        let store = runtime.store
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
        runtime.invalidationTask = invalidationTask
        runtime.invalidationID = invalidationID
        await invalidationTask.value
    }

    private func finishInvalidation(
        accountKey: String,
        invalidationID: UUID,
        releaseRuntimeState: Bool
    ) async {
        guard let runtime = runtimes[accountKey],
              runtime.invalidationID == invalidationID else { return }
        if releaseRuntimeState {
            let lateScanner = runtime.scanner
            runtime.resetGeneration()
            let lateActiveTasks = runtime.takeActiveScanTasks()
            let lateDrainingTasks = runtime.takeDrainingScanTasks()
            let lateTasks = Array(lateActiveTasks.merging(
                lateDrainingTasks,
                uniquingKeysWith: { current, _ in current }
            ).values)
            lateTasks.forEach { $0.cancel() }
            await lateScanner?.invalidate()
            await runtime.store.invalidateScanGeneration()
            for task in lateTasks {
                await task.value
            }
            runtime.enricher = nil
            let removedLocalEnricher = runtime.localEnricher
            let removedArtworkProbeWorker = runtime.artworkProbeWorker
            runtime.localEnricher = nil
            runtime.artworkProbeWorker = nil
            await metadataScheduler.remove(accountKey: accountKey)
            await removedLocalEnricher?.close()
            await removedArtworkProbeWorker?.close()
            reporter.shareRemoved(accountKey)
            // Retire the per-account arbiter (finding A7): reject new admission, drain
            // any active scanner under the bounded deadline, and wait for already-issued
            // playback leases to drain naturally. Drop the runtime (and with it the
            // arbiter) only after it drains, and only if the table still points at THIS
            // identity — a re-add after this completed invalidation installs a fresh
            // runtime/arbiter generation that must survive. This awaits genuine playback
            // lifetime but never a hung scanner.
            await runtime.arbiter.shutdownAndDrain()
            if runtimes[accountKey] === runtime {
                runtimes[accountKey] = nil
            }
            return
        }
        // Credential rotation preserves the runtime; just clear the invalidation
        // handle and restart flag so a waiting `store(...)`/`rescan(...)` proceeds.
        runtime.restarting = false
        runtime.invalidationTask = nil
        runtime.invalidationID = nil
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
