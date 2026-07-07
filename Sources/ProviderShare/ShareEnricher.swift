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
    /// Max items fetched into a single drain snapshot. Defaults to "the whole
    /// backlog" (`.max`): a partial cap left large libraries perpetually under-
    /// enriched — the pass only re-triggers on the next scan/Home load, so
    /// heroes/cards stayed blank for most of the library. A pass processes a finite
    /// snapshot exactly once, so it always terminates; usable results settle while
    /// misses stay pending (bounded retries) for a later pass. Tests pass a small
    /// cap to bound a single run.
    private let maxPerRun: Int
    private var isRunning = false
    /// Whether this pass advertised "enriching" (had work). Lets `setReporter`
    /// replay `enrichStarted` to a reporter wired mid-pass without leaving the
    /// banner stuck when the pass was a no-op.
    private var isAdvertisingEnrich = false

    init(store: ShareCatalogStore, resolver: ShareMetadataResolving, shareID: String = "",
         reporter: ShareScanReporter = .noop, concurrency: Int = 6, maxPerRun: Int = .max) {
        self.store = store
        self.resolver = resolver
        self.shareID = shareID
        self.reporter = reporter
        self.concurrency = max(1, concurrency)
        self.maxPerRun = maxPerRun
    }

    /// Re-point progress reporting after creation (startup race — see ShareScanner).
    /// Replay `enrichStarted` when a pass is currently advertising work, so a
    /// reporter wired mid-pass still sees the in-flight enrichment (and its matching
    /// `enrichFinished`).
    func setReporter(_ reporter: ShareScanReporter) {
        self.reporter = reporter
        if isAdvertisingEnrich { reporter.enrichStarted(shareID) }
    }

    /// Resolve + persist pending items until none remain (or the run cap / cancel).
    func enrichPending() async {
        if isRunning { return }
        isRunning = true
        // Only advertise "enriching" when there's actually pending work, so the
        // banner doesn't blink for a no-op pass.
        let hasWork = !(await store.pendingEnrichment(version: Self.version, limit: 1)).isEmpty
        isAdvertisingEnrich = hasWork
        if hasWork { reporter.enrichStarted(shareID) }
        defer { isRunning = false; isAdvertisingEnrich = false; if hasWork { reporter.enrichFinished(shareID) } }

        // Process ONE snapshot of the currently-pending items, each exactly once.
        // A re-query-from-the-top loop stalls once retry-eligible misses persist at
        // the front of the ordering (and could spin forever if a write kept
        // failing); a finite snapshot drains cleanly and always terminates. Items
        // scanned in later are picked up by the next pass (kicked after each scan).
        let snapshot = await store.pendingEnrichment(version: Self.version, limit: maxPerRun)
        if snapshot.isEmpty { return }

        var processed = 0
        await withTaskGroup(of: (String, ShareCatalogStore.EnrichmentRecord).self) { group in
            var iterator = snapshot.makeIterator()
            let resolver = self.resolver
            func addNext() -> Bool {
                guard !Task.isCancelled, let pending = iterator.next() else { return false }
                let request = ShareEnrichRequest(
                    itemID: pending.itemID, title: pending.title, year: pending.year,
                    isMovie: pending.isMovie, isAnime: pending.isAnime
                )
                group.addTask { (pending.itemID, await resolver.resolve(request)) }
                return true
            }
            for _ in 0..<concurrency { _ = addNext() }
            while let (itemID, record) = await group.next() {
                // Persist the (merged) result. A usable result settles the item; an
                // unusable miss bumps its attempt counter and stays pending for the
                // next pass, up to the retry cap — so a transient rate-limit/timeout
                // isn't cached as a permanent blank. Count only durable writes.
                let ok = await store.saveEnrichment(itemID: itemID, record, version: Self.version)
                if ok { processed += 1 }
                if Task.isCancelled { break }
                _ = addNext()
            }
        }
        PlozzLog.boot("share.enrich pass done processed=\(processed)/\(snapshot.count) cancelled=\(Task.isCancelled)")
    }

    /// Resolve + persist ONE item immediately (the one a user just opened), jumping
    /// it ahead of the background backlog so its art/overview/ids land promptly. A
    /// no-op when the item is already enriched at the current version or isn't a
    /// logical movie/series. Runs independently of `enrichPending` (no `isRunning`
    /// guard) so opening an item during a full drain still fast-tracks it.
    func enrichOne(itemID: String) async {
        guard let pending = await store.pendingEnrichment(forItemID: itemID, version: Self.version) else { return }
        let request = ShareEnrichRequest(
            itemID: pending.itemID, title: pending.title, year: pending.year,
            isMovie: pending.isMovie, isAnime: pending.isAnime
        )
        let record = await resolver.resolve(request)
        guard !Task.isCancelled else { return }
        await store.saveEnrichment(itemID: pending.itemID, record, version: Self.version)
    }
}
