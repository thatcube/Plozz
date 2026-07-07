import Foundation
import CoreModels
import MetadataKit

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
    /// Where scan/enrich progress is reported for the Home banner + Settings.
    /// Wired once by the app (`AppState`); `.noop` until then (tests/previews).
    private var reporter: ShareScanReporter = .noop

    private init() {}

    /// Inject the app's scan-status reporter (call once at startup). Applies to
    /// scanners/enrichers created after this point — which is every real one, since
    /// the app configures the registry before Home first queries a share.
    func configure(reporter: ShareScanReporter) {
        self.reporter = reporter
    }

    /// Return the shared catalog store for a share, creating it (and a dedicated
    /// scan `SMBShareBrowser` + scanner + enricher) on first use, and kicking a
    /// throttled background scan followed by enrichment. The scan browser is
    /// separate from the interactive one so a walk never starves live browsing.
    func store(
        accountKey: String,
        displayName: String,
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
            let scanner = ShareScanner(store: store, shareID: accountKey, name: displayName, reporter: reporter) { relPath in
                try await browser.listDirectory(relPath)
            }
            scanners[accountKey] = scanner
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

    /// Force a fresh scan + enrichment now, bypassing the staleness throttle — the
    /// "Scan now" control in Settings. No-op if the share isn't registered yet.
    func rescan(accountKey: String) {
        guard scanTasks[accountKey] == nil,
              let scanner = scanners[accountKey],
              let enricher = enrichers[accountKey] else { return }
        scanTasks[accountKey] = Task { [weak self] in
            await scanner.scan()
            await enricher.enrichPending()
            await self?.clearScanTask(accountKey)
        }
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

/// Public control surface over the (internal) `ShareCatalogRegistry`, so the app
/// layer can wire the scan-status reporter and trigger a manual rescan without
/// seeing the registry's internal types.
public enum ShareLibraryControl {
    /// Wire the app's scan-status reporter into the registry (call once at startup,
    /// before Home first queries a share).
    public static func configure(reporter: ShareScanReporter) async {
        await ShareCatalogRegistry.shared.configure(reporter: reporter)
    }

    /// Force a fresh scan + enrichment of a share now (the Settings "Scan now"
    /// action). `shareID` is the share account's `server.id`.
    public static func rescan(shareID: String) async {
        await ShareCatalogRegistry.shared.rescan(accountKey: shareID)
    }
}
