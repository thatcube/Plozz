import Foundation
import CoreModels
import CoreNetworking
import MetadataKit

/// Second pass after a scan: resolves + persists metadata (external ids, overview,
/// artwork) for indexed movies/series that lack it, so a share's cards and detail
/// pages become rich and — crucially — carry the external ids that let a share
/// title merge with its Plex/Jellyfin twin, pull external ratings, and scrobble.
///
/// Foreground, incremental, cancellation-safe, and bounded: it processes a few
/// items concurrently, persists each result (marking it done at the current
/// enrichment version so it isn't re-fetched), and stops cleanly on cancel or when
/// nothing is pending. Kicked by `ShareCatalogCoordinator` after each scan.
actor ShareEnricher {
    /// Bump when the resolver's output materially changes, to re-enrich everything.
    /// v2: TVDB same-name collisions now disambiguate by on-disk episode titles
    /// (fixes e.g. animated "Archer" matching the 1975 detective drama).
    /// v3: series titles are normalized and now carry a year, so re-enrich to pick
    /// up clean titles + year-based disambiguation.
    /// v4: a generic show folder ("Avatar (2024)") also searches richer
    /// filename-derived titles ("Avatar The Last Airbender"), so re-enrich.
    /// v5: robust series keys (article/apostrophe folding) + a representative
    /// (most-common) series year instead of MAX, so re-enrich with the corrected
    /// grouping and years.
    /// v6: resolve directly by an explicit [tvdb-####] folder tag, upgrade a generic
    /// folder title to the resolved canonical name, and feed that name+year into
    /// artwork so the logo matches the right same-named show.
    /// v7: re-enrich after the nested-spinoff regroup so a parent show whose hints
    /// were previously polluted (The Witcher, absorbing Blood Origin) resolves to its
    /// own id; also fetch the English overview for id-resolved shows (One Piece).
    /// v8: id-corroborated series reconciliation — fold a typo'd folder ("Peaky
    /// Blinder") into its twin ("Peaky Blinders") when both resolve to the same
    /// strong external id. Re-enrich so the merge runs on existing catalogs.
    static let version = 8

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
    /// Snapshot size + items attempted in the current pass, retained so a reporter
    /// wired mid-pass can be replayed the live totals (see `setReporter`).
    private var enrichTotal = 0
    private var enrichDone = 0

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
    /// Replay `enrichStarted` (+ the latest progress) when a pass is currently
    /// advertising work, so a reporter wired mid-pass sees the in-flight enrichment
    /// (and its matching `enrichFinished`).
    func setReporter(_ reporter: ShareScanReporter) {
        self.reporter = reporter
        if isAdvertisingEnrich {
            reporter.enrichStarted(shareID, enrichTotal)
            if enrichDone > 0 { reporter.enrichProgress(shareID, enrichDone) }
        }
    }

    /// Resolve + persist pending items until none remain (or the run cap / cancel).
    func enrichPending() async {
        if isRunning { return }
        isRunning = true

        // Fetch the snapshot up front so we know the pass total (for the progress
        // indicator) before advertising. An empty snapshot is a no-op pass — no
        // banner blink.
        let snapshot = await store.pendingEnrichment(version: Self.version, limit: maxPerRun)
        let total = snapshot.count
        isAdvertisingEnrich = total > 0
        enrichTotal = total
        enrichDone = 0
        if total > 0 { reporter.enrichStarted(shareID, total) }
        defer {
            isRunning = false
            isAdvertisingEnrich = false
            enrichTotal = 0
            enrichDone = 0
            if total > 0 { reporter.enrichFinished(shareID) }
        }
        if snapshot.isEmpty { return }

        // Process the snapshot exactly once. A re-query-from-the-top loop stalls once
        // retry-eligible misses persist at the front of the ordering (and could spin
        // forever if a write kept failing); a finite snapshot drains cleanly and
        // always terminates. Items scanned in later are picked up by the next pass.
        var processed = 0
        var attempted = 0
        await withTaskGroup(of: (String, ShareCatalogStore.EnrichmentRecord).self) { group in
            var iterator = snapshot.makeIterator()
            let resolver = self.resolver
            func addNext() -> Bool {
                guard !Task.isCancelled, let pending = iterator.next() else { return false }
                group.addTask { [self] in
                    let request = await self.request(for: pending)
                    return (pending.itemID, await resolver.resolve(request))
                }
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
                // Progress advances per item ATTEMPTED (misses included) so the bar
                // reflects queue position, not just successful writes.
                attempted += 1
                enrichDone = attempted
                reporter.enrichProgress(shareID, attempted)
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
        let request = await request(for: pending)
        let record = await resolver.resolve(request)
        guard !Task.isCancelled else { return }
        await store.saveEnrichment(itemID: pending.itemID, record, version: Self.version)
    }

    /// Builds the resolve request for a pending item, attaching on-disk episode
    /// title hints for a series so a same-name metadata collision can be resolved
    /// by content (see ``TVDBClient`` disambiguation). No hints for movies.
    private func request(for pending: ShareCatalogStore.PendingEnrichment) async -> ShareEnrichRequest {
        var hints: [SeriesEpisodeHint] = []
        var alternates: [String] = []
        var knownTVDBID: String?
        if !pending.isMovie, let key = ShareCatalogID.seriesKey(forSeriesID: pending.itemID) {
            hints = await store.episodeTitleHints(seriesKey: key).map {
                SeriesEpisodeHint(season: $0.season, episode: $0.episode, title: $0.title)
            }
            alternates = await store.seriesSearchTitleAlternates(seriesKey: key, storedTitle: pending.title)
            knownTVDBID = await store.seriesEmbeddedTVDBID(seriesKey: key)
        }
        return ShareEnrichRequest(
            itemID: pending.itemID, title: pending.title, year: pending.year,
            isMovie: pending.isMovie, isAnime: pending.isAnime, episodeHints: hints,
            titleAlternates: alternates, knownTVDBID: knownTVDBID
        )
    }
}
