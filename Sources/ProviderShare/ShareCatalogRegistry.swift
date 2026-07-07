import Foundation

/// Process-wide cache of one `ShareCatalogStore` + `ShareScanner` per share
/// account. `ShareProvider` is a value type SwiftUI rebuilds constantly, so the
/// catalog and the in-flight scan must live *outside* it — otherwise every
/// re-render would spin up a new SQLite handle and restart scanning. Keyed by the
/// share's `server.id` (same key `ShareWatchStore` uses).
actor ShareCatalogRegistry {
    static let shared = ShareCatalogRegistry()

    private var stores: [String: ShareCatalogStore] = [:]
    private var scanners: [String: ShareScanner] = [:]
    private var enrichers: [String: ShareEnricher] = [:]
    private var scanTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Return the shared catalog store for a share, creating it (and a dedicated
    /// scan `SMBShareBrowser` + scanner + enricher) on first use, and kicking a
    /// throttled background scan followed by enrichment. The scan browser is
    /// separate from the interactive one so a walk never starves live browsing.
    func store(
        accountKey: String,
        host: String,
        port: Int?,
        share: String,
        user: String,
        password: String
    ) -> ShareCatalogStore {
        let store = stores[accountKey] ?? {
            let created = ShareCatalogStore(accountKey: accountKey)
            stores[accountKey] = created
            return created
        }()

        if scanners[accountKey] == nil {
            let browser = SMBShareBrowser(host: host, port: port, share: share, user: user, password: password)
            let scanner = ShareScanner(store: store) { relPath in
                try await browser.listDirectory(relPath)
            }
            scanners[accountKey] = scanner
        }
        if enrichers[accountKey] == nil {
            enrichers[accountKey] = ShareEnricher(store: store, resolver: KeylessShareResolver())
        }
        ensureScanning(accountKey)
        return store
    }

    /// Spawn a throttled scan attempt (then an enrichment pass) unless one is
    /// already in flight for this share. `ShareScanner.scanIfStale` time-throttles
    /// the real walk, so a rapid burst of Home reloads collapses to one run.
    private func ensureScanning(_ accountKey: String) {
        guard scanTasks[accountKey] == nil,
              let scanner = scanners[accountKey],
              let enricher = enrichers[accountKey] else { return }
        scanTasks[accountKey] = Task { [weak self] in
            await scanner.scanIfStale()
            // Enrich whatever the scan (and prior scans) indexed. Cheap no-op when
            // nothing is pending.
            await enricher.enrichPending()
            await self?.clearScanTask(accountKey)
        }
    }

    private func clearScanTask(_ accountKey: String) {
        scanTasks[accountKey] = nil
    }
}
