import Foundation
import CoreModels
import CoreNetworking

/// Second pass after a scan: resolves + persists metadata (external ids, overview,
/// artwork) for indexed movies/series that lack it, so a share's cards and detail
/// pages become rich and — crucially — carry the external ids that let a share
/// title merge with its Plex/Jellyfin twin, pull external ratings, and scrobble.
///
/// Foreground, incremental, cancellation-safe, and bounded: it processes a few
/// items concurrently, persists each result (marking it done at the current
/// enrichment version so it isn't re-fetched), and stops cleanly on cancel or when
/// nothing is pending. Kicked by `ShareCatalogRegistry` after each scan.
actor ShareEnricher {
    /// Bump when the resolver's output materially changes, to re-enrich everything.
    static let version = 1

    private let store: ShareCatalogStore
    private let resolver: ShareMetadataResolving
    private let shareID: String
    private var reporter: ShareScanReporter
    /// How many items to resolve concurrently (each is a handful of small HTTP
    /// calls to keyless APIs — keep modest so a large library doesn't burst).
    private let concurrency: Int
    /// Safety cap on items enriched per run so one pass can't spin unbounded.
    private let maxPerRun: Int
    private var isRunning = false

    init(store: ShareCatalogStore, resolver: ShareMetadataResolving, shareID: String = "",
         reporter: ShareScanReporter = .noop, concurrency: Int = 6, maxPerRun: Int = 400) {
        self.store = store
        self.resolver = resolver
        self.shareID = shareID
        self.reporter = reporter
        self.concurrency = max(1, concurrency)
        self.maxPerRun = maxPerRun
    }

    /// Re-point progress reporting after creation (startup race — see ShareScanner).
    func setReporter(_ reporter: ShareScanReporter) { self.reporter = reporter }

    /// Resolve + persist pending items until none remain (or the run cap / cancel).
    func enrichPending() async {
        if isRunning { return }
        isRunning = true
        // Only advertise "enriching" when there's actually pending work, so the
        // banner doesn't blink for a no-op pass.
        let hasWork = !(await store.pendingEnrichment(version: Self.version, limit: 1)).isEmpty
        if hasWork { reporter.enrichStarted(shareID) }
        defer { isRunning = false; if hasWork { reporter.enrichFinished(shareID) } }

        var processed = 0
        while !Task.isCancelled, processed < maxPerRun {
            let batch = await store.pendingEnrichment(version: Self.version, limit: concurrency * 3)
            if batch.isEmpty { break }

            await withTaskGroup(of: (String, ShareCatalogStore.EnrichmentRecord).self) { group in
                var iterator = batch.makeIterator()
                let resolver = self.resolver
                func addNext() -> Bool {
                    guard let pending = iterator.next() else { return false }
                    let request = ShareEnrichRequest(
                        itemID: pending.itemID, title: pending.title, year: pending.year,
                        isMovie: pending.isMovie, isAnime: pending.isAnime
                    )
                    group.addTask { (pending.itemID, await resolver.resolve(request)) }
                    return true
                }
                for _ in 0..<concurrency { _ = addNext() }
                while let (itemID, record) = await group.next() {
                    // Persist even a sparse result: it marks the item done at this
                    // version so a miss isn't retried every pass (a version bump or
                    // manual refresh re-enriches). Keeps the pending set shrinking.
                    await store.saveEnrichment(itemID: itemID, record, version: Self.version)
                    processed += 1
                    if Task.isCancelled { break }
                    _ = addNext()
                }
            }
        }
        PlozzLog.boot("share.enrich pass done processed=\(processed) cancelled=\(Task.isCancelled)")
    }
}
