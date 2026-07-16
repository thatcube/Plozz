import Foundation
import CoreModels
import MediaTransportCore
import MetadataKit

protocol ShareCatalogCoordinating: Sendable {
    func store(
        accountKey: String,
        displayName: String,
        credentialRevision: CredentialRevision,
        sessionFactory: @escaping ShareTransportSessionFactory
    ) async -> ShareCatalogStore
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
    private var pacers: [String: ShareScanPacer] = [:]
    private var scanTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private var drainingScanTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private var invalidationTasks: [String: Task<Void, Never>] = [:]
    private var invalidationTaskIDs: [String: UUID] = [:]
    private var restartingScans: Set<String> = []
    private var arbiters: [String: MediaIOArbiter] = [:]
    private let metadataScheduler = ShareMetadataWorkScheduler()
    private let arbiterFactory: ArbiterFactory
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

    public init(
        arbiterFactory: @escaping ArbiterFactory = { MediaIOArbiter(accountID: $0) }
    ) {
        self.arbiterFactory = arbiterFactory
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
                await invalidateScanner(
                    accountKey: accountKey,
                    store: store,
                    releaseRuntimeState: false
                )
                continue
            }

            if scanners[accountKey] == nil {
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
                // Use the bundled TheTVDB tier when a key is configured (adds movie ids
                // + posters that the keyless sources can't provide); otherwise the
                // keyless base carries enrichment on its own.
                let resolver: ShareMetadataResolving
                let tvdbConfig = TVDBConfig.resolved()
                if tvdbConfig.isConfigured {
                    resolver = TVDBShareResolver(tvdb: TVDBClient(config: tvdbConfig))
                } else {
                    resolver = KeylessShareResolver()
                }
                let enricher = ShareEnricher(
                    store: store,
                    resolver: resolver,
                    shareID: accountKey,
                    reporter: reporter
                )
                enrichers[accountKey] = enricher
                let arbiter = arbiter(for: accountKey)
                await metadataScheduler.register(
                    accountKey: accountKey,
                    mayRun: { await arbiter.permitsBackgroundWork() },
                    runSlice: { maxItems, maxDuration in
                        ShareBackgroundActivity.enrichStarted()
                        BrowseDiagnostics.event("enrich-slice+ \(accountKey)")
                        let result = await enricher.enrichPendingSlice(
                            maxItems: maxItems,
                            maxDuration: maxDuration
                        )
                        BrowseDiagnostics.event(
                            "enrich-slice- \(accountKey) attempted=\(result.attempted) more=\(result.hasMore)"
                        )
                        ShareBackgroundActivity.enrichFinished()
                        return result
                    },
                    runItem: { itemID in
                        ShareBackgroundActivity.enrichStarted()
                        BrowseDiagnostics.event("enrich-item+ \(accountKey)")
                        await enricher.enrichOne(itemID: itemID)
                        BrowseDiagnostics.event("enrich-item- \(accountKey)")
                        ShareBackgroundActivity.enrichFinished()
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
    func rescan(accountKey: String) async {
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

    /// Fast-track enrichment of ONE item the user just opened, ahead of the
    /// background backlog, so its hero/poster/overview persist promptly (and the
    /// persisted art then supersedes the flaky live title-only fallback). Spawns a
    /// background task and returns immediately — callers on the detail hot path add
    /// no latency. No-op if the share was never registered or the item is already
    /// enriched.
    func enrichItem(accountKey: String, itemID: String) async {
        guard enrichers[accountKey] != nil else { return }
        await metadataScheduler.enqueueItem(accountKey: accountKey, itemID: itemID)
    }

    func noteInteractiveActivity(accountKey: String) async {
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
                await self?.clearScanTask(accountKey, taskID: taskID)
                return
            }
            ShareBackgroundActivity.scanStarted()
            BrowseDiagnostics.event("scan+ \(accountKey) force=\(force)")
            if force {
                await scanner.scan()
            } else {
                await scanner.scanIfStale()
            }
            ShareBackgroundActivity.scanFinished()
            BrowseDiagnostics.event("scan- \(accountKey)")
            resource.markDrained()
            await scannerLease.finishAndWait()
            if !Task.isCancelled {
                await self?.metadataScheduler.enqueueBacklog(accountKey: accountKey)
            }
            // Record scan completion so `ensureScanning` coalesces the frequent
            // per-render re-triggers into at most one cycle per window. A forced
            // "Scan now" also resets it, so a manual scan doesn't immediately
            // re-thrash on the next Home render.
            await self?.noteScanCompleted(accountKey)
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
    }

    /// Records that a background scan+enrich cycle finished for this share, so
    /// `ensureScanning` coalesces the frequent per-render re-triggers.
    private func noteScanCompleted(_ accountKey: String) {
        lastBackgroundScanCompletedAt[accountKey] = Date()
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
            pacers[accountKey] = nil
            await metadataScheduler.remove(accountKey: accountKey)
            reporter.shareRemoved(accountKey)
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

private final class ShareScannerResource: MediaIOScannerResource, @unchecked Sendable {
    private let scanner: ShareScanner
    private let store: ShareCatalogStore
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    private var drained = false

    init(scanner: ShareScanner, store: ShareCatalogStore) {
        self.scanner = scanner
        self.store = store
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

    func cancel() async {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
        await store.invalidateScanGeneration()
    }

    func forceClose() async throws {
        await cancel()
        await scanner.forceCloseActiveListers()
        lock.withLock {
            drained = true
        }
    }
}
