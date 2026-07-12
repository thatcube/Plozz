import Foundation
import CoreModels
import MetadataKit

/// Process-wide cache of one `ShareCatalogStore` + `ShareScanner` per share
/// account. `ShareProvider` is a value type SwiftUI rebuilds constantly, so the
/// catalog and the in-flight scan must live *outside* it — otherwise every
/// re-render would spin up a new SQLite handle and restart scanning. Keyed by the
/// the configured account id (the same key `ShareWatchStore` uses), so separate
/// principals on one endpoint never share catalog or scanner state.
actor ShareCatalogRegistry {
    static let shared = ShareCatalogRegistry()

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
    /// Where scan/enrich progress is reported for the Home banner + Settings.
    /// Wired once by the app (`AppState`); `.noop` until then (tests/previews).
    private var reporter: ShareScanReporter = .noop

    private init() {}

    /// Inject the app's scan-status reporter (call once at startup). Applies to
    /// future scanners/enrichers AND back-fills any already created before this
    /// ran (a startup race: the app configures the reporter from an async Task in
    /// its init, which can land after Home's first share query created a scanner
    /// with the `.noop` default — that left the banner + last-scanned line dead).
    func configure(reporter: ShareScanReporter) async {
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
                enrichers[accountKey] = ShareEnricher(store: store, resolver: resolver, shareID: accountKey, reporter: reporter)
            }
            ensureScanning(accountKey)
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
        startScan(accountKey: accountKey, scanner: scanner, force: true)
    }

    func invalidate(accountKey: String) async {
        while true {
            if let invalidationTask = invalidationTasks[accountKey] {
                await invalidationTask.value
                continue
            }
            guard let store = stores[accountKey] else { return }
            await invalidateScanner(
                accountKey: accountKey,
                store: store,
                releaseRuntimeState: true
            )
            return
        }
    }

    /// Fast-track enrichment of ONE item the user just opened, ahead of the
    /// background backlog, so its hero/poster/overview persist promptly (and the
    /// persisted art then supersedes the flaky live title-only fallback). Spawns a
    /// background task and returns immediately — callers on the detail hot path add
    /// no latency. No-op if the share was never registered or the item is already
    /// enriched.
    func enrichItem(accountKey: String, itemID: String) {
        guard let enricher = enrichers[accountKey] else { return }
        Task { await enricher.enrichOne(itemID: itemID) }
    }

    func noteInteractiveActivity(accountKey: String) async {
        let pacer = pacers[accountKey] ?? {
            let created = ShareScanPacer()
            pacers[accountKey] = created
            return created
        }()
        await pacer.noteInteractiveActivity()
    }

    /// Spawn a throttled scan attempt (then an enrichment pass) unless one is
    /// already in flight for this share. `ShareScanner.scanIfStale` time-throttles
    /// the real walk, so a rapid burst of Home reloads collapses to one run.
    private func ensureScanning(_ accountKey: String) {
        guard scanTasks[accountKey]?.isEmpty != false,
              !restartingScans.contains(accountKey),
              let scanner = scanners[accountKey] else { return }
        startScan(accountKey: accountKey, scanner: scanner, force: false)
    }

    private func startScan(
        accountKey: String,
        scanner: ShareScanner,
        force: Bool
    ) {
        guard let enricher = enrichers[accountKey] else { return }
        let taskID = UUID()
        let task = Task(priority: .utility) { [weak self] in
            ShareBackgroundActivity.scanStarted()
            if force {
                await scanner.scan()
            } else {
                await scanner.scanIfStale()
            }
            ShareBackgroundActivity.scanFinished()
            // Enrich whatever the scan (and prior scans) indexed. Cheap no-op when
            // nothing is pending.
            if !Task.isCancelled {
                ShareBackgroundActivity.enrichStarted()
                await enricher.enrichPending()
                ShareBackgroundActivity.enrichFinished()
            }
            await self?.clearScanTask(accountKey, taskID: taskID)
        }
        scanTasks[accountKey, default: [:]][taskID] = task
    }

    private func clearScanTask(_ accountKey: String, taskID: UUID) {
        scanTasks[accountKey]?[taskID] = nil
        if scanTasks[accountKey]?.isEmpty == true {
            scanTasks[accountKey] = nil
        }
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
        }
        restartingScans.remove(accountKey)
        invalidationTasks[accountKey] = nil
        invalidationTaskIDs[accountKey] = nil
    }
}

/// Public control surface over the (internal) `ShareCatalogRegistry`, so the app
/// layer can wire the scan-status reporter without seeing the registry's internal
/// types. (Rescan is driven through `ShareProvider.rescan()` instead, so it can
/// register the share's catalog on demand.)
public enum ShareLibraryControl {
    /// Wire the app's scan-status reporter into the registry (call once at startup).
    /// Back-fills any scanners already created before this ran.
    public static func configure(reporter: ShareScanReporter) async {
        await ShareCatalogRegistry.shared.configure(reporter: reporter)
    }

    public static func invalidate(accountKey: String) async {
        await ShareCatalogRegistry.shared.invalidate(accountKey: accountKey)
    }
}
