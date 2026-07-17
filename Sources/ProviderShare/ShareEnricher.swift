import Foundation
import CoreModels
import CoreNetworking
import MetadataKit

/// Second pass after a scan: resolves + persists metadata (external ids, overview,
/// artwork) for indexed movies/series that lack it, so a share's cards and detail
/// pages become rich and — crucially — carry the external ids that let a share
/// title merge with its Plex/Jellyfin twin, pull external ratings, and scrobble.
///
/// Incremental, cancellation-safe, and bounded: the app-wide metadata scheduler
/// feeds it short sequential slices, while an opened item can jump ahead through
/// `enrichOne`. Results persist at the current enrichment version so work resumes
/// from SQLite after interruption or relaunch.
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
    /// v9: reject non-canonical variant matches (a "Sword Art Online" folder no
    /// longer resolves to the "Abridged" parody) and prefer the English name/overview
    /// on the title-search path too (fixes Japanese descriptions for Death Note,
    /// "…Slime", etc.). Re-enrich to correct them.
    /// v10: episode-title hints skip synthetic "S1·E01" placeholders, so a show with
    /// bare-numbered early seasons (Outlander) sends its real later-season titles and
    /// disambiguates to the right show instead of a same-named foreign series.
    /// v11: a release year after the episode marker ("Show S01E01 2025 …") is now
    /// captured as the series year, enabling year-based disambiguation (The Eternaut
    /// 2025 vs a same-fuzzy-named older title). Re-enrich to use it.
    /// v12: episode-title disambiguation scores exact-name matches first and more
    /// candidates (a popular show ranking below a foreign namesake — Outlander vs
    /// "O Caçador" — is now scored), and a cryptic filename abbreviation ("TP" under
    /// a "The Punisher" folder) is no longer used as a search alternate.
    /// v13: a re-enrich after a version bump now REPLACES the stored record instead
    /// of merging, so stale artwork from a previous wrong match is dropped (a "TP"
    /// folder that once cached TAP Portugal's logo no longer keeps it under the
    /// corrected "The Punisher").
    /// v14: prefer the English title too (not just non-Latin overviews) when the
    /// resolved name doesn't resemble the searched title — TheTVDB serves a foreign
    /// primary name in Latin script for some shows ("The Eternaut" → "El eternauta").
    static let version = 14

    private let store: ShareCatalogStore
    private let resolver: ShareMetadataResolving
    private let shareID: String
    private var reporter: ShareScanReporter
    /// Compatibility cap for the legacy/test `enrichPending` entry point. Production
    /// passes a smaller per-slice limit through `ShareMetadataWorkScheduler`.
    private let maxPerRun: Int
    private var isRunning = false
    private var isPassActive = false
    /// Whether this pass advertised "enriching" (had work). Lets `setReporter`
    /// replay `enrichStarted` to a reporter wired mid-pass without leaving the
    /// banner stuck when the pass was a no-op.
    private var isAdvertisingEnrich = false
    /// Snapshot size + items attempted in the current pass, retained so a reporter
    /// wired mid-pass can be replayed the live totals (see `setReporter`).
    private var enrichTotal = 0
    private var enrichDone = 0
    private var advertisedAttemptedItemIDs: Set<String> = []
    private var passStartedAt: Date?

    init(store: ShareCatalogStore, resolver: ShareMetadataResolving, shareID: String = "",
         reporter: ShareScanReporter = .noop, concurrency _: Int = 1, maxPerRun: Int = .max) {
        self.store = store
        self.resolver = resolver
        self.shareID = shareID
        self.reporter = reporter
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

    /// Legacy/test entry point: resolves one snapshot up to `maxPerRun`, then closes
    /// its progress report. Production uses `enrichPendingSlice`.
    func enrichPending() async {
        let result = await runSlice(
            maxItems: maxPerRun,
            maxDuration: nil
        )
        if result.hasMore {
            finishLogicalPass()
        }
    }

    /// Resolves one passive scheduler slice. Progress remains open across slices and
    /// closes only when the backlog drains or the slice is interrupted.
    func enrichPendingSlice(
        maxItems: Int,
        maxDuration: Duration,
        beforeResolve: (@Sendable (String) async -> Bool)? = nil
    ) async -> ShareEnrichmentSliceResult {
        await runSlice(
            maxItems: maxItems,
            maxDuration: maxDuration,
            beforeResolve: beforeResolve
        )
    }

    private func runSlice(
        maxItems: Int,
        maxDuration: Duration?,
        beforeResolve: (@Sendable (String) async -> Bool)? = nil
    ) async -> ShareEnrichmentSliceResult {
        if isRunning {
            return ShareEnrichmentSliceResult(attempted: 0, hasMore: true)
        }
        isRunning = true
        defer { isRunning = false }

        if !isPassActive {
            let startedAt = Date()
            enrichTotal = await store.pendingEnrichmentCount(
                version: Self.version,
                discoveredBefore: startedAt
            )
            guard enrichTotal > 0 else {
                return ShareEnrichmentSliceResult(attempted: 0, hasMore: false)
            }
            enrichDone = 0
            passStartedAt = startedAt
            isPassActive = true
        }
        if !isAdvertisingEnrich {
            isAdvertisingEnrich = true
            reporter.enrichStarted(shareID, enrichTotal)
            if enrichDone > 0 {
                reporter.enrichProgress(shareID, enrichDone)
            }
        }

        let limit = min(max(1, maxItems), maxPerRun)
        let snapshot = await store.pendingEnrichment(
            version: Self.version,
            limit: limit,
            passStartedAt: passStartedAt
        )
        if snapshot.isEmpty {
            finishLogicalPass()
            return ShareEnrichmentSliceResult(attempted: 0, hasMore: false)
        }

        let clock = ContinuousClock()
        let started = clock.now
        var processed = 0
        var attempted = 0
        var deferred = 0
        var writeFailures = 0
        for pending in snapshot {
            if Task.isCancelled { break }
            if let beforeResolve, !(await beforeResolve(pending.itemID)) {
                deferred += 1
                continue
            }
            let request = await request(for: pending)
            let record = await resolver.resolve(request)
            if Task.isCancelled { break }
            let ok = await store.saveEnrichment(
                itemID: pending.itemID,
                record,
                version: Self.version
            )
            if ok {
                processed += 1
            } else {
                writeFailures += 1
            }
            attempted += 1
            if advertisedAttemptedItemIDs.insert(pending.itemID).inserted {
                enrichDone += 1
                reporter.enrichProgress(shareID, enrichDone)
            }
            if let maxDuration,
               started.duration(to: clock.now) >= maxDuration {
                break
            }
        }

        let madeDurableProgress = processed > 0
        let hasMore = Task.isCancelled
            || deferred > 0
            || writeFailures > 0
            || (
                madeDurableProgress
                && (attempted < snapshot.count || snapshot.count == limit)
            )
        let retryAfter: Duration? = if deferred > 0 {
            .seconds(5)
        } else if writeFailures == 0 {
            nil
        } else if madeDurableProgress {
            .seconds(5)
        } else {
            .seconds(30)
        }
        if Task.isCancelled {
            pauseScheduledPass()
        } else if !hasMore {
            finishLogicalPass()
        }
        PlozzLog.boot(
            "share.enrich slice done processed=\(processed)/\(snapshot.count) "
                + "attempted=\(attempted) more=\(hasMore) cancelled=\(Task.isCancelled)"
        )
        return ShareEnrichmentSliceResult(
            attempted: attempted,
            hasMore: hasMore,
            retryAfter: retryAfter
        )
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
        let saved = await store.saveEnrichment(
            itemID: pending.itemID,
            record,
            version: Self.version
        )
        if saved,
           isPassActive,
           pending.discoveredAt <= (passStartedAt ?? .distantPast),
           advertisedAttemptedItemIDs.insert(pending.itemID).inserted {
            enrichDone += 1
            if isAdvertisingEnrich {
                reporter.enrichProgress(shareID, enrichDone)
            }
        }
    }

    func pauseScheduledPass() {
        guard isAdvertisingEnrich else { return }
        isAdvertisingEnrich = false
        reporter.enrichFinished(shareID)
    }

    func finishLogicalPass() {
        pauseScheduledPass()
        guard isPassActive else { return }
        isPassActive = false
        enrichTotal = 0
        enrichDone = 0
        advertisedAttemptedItemIDs.removeAll(keepingCapacity: true)
        passStartedAt = nil
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
        // Already-persisted local (NFO/filename) ids let a provider that supports
        // exact-id resolution skip fuzzy title search (see
        // `ShareEnrichRequest.knownProviderIDs`) — never reorders existing
        // sources, only seeds them.
        let knownProviderIDs = await store.localProviderIDs(forItemID: pending.itemID)
        return ShareEnrichRequest(
            itemID: pending.itemID, title: pending.title, year: pending.year,
            isMovie: pending.isMovie, isAnime: pending.isAnime, episodeHints: hints,
            titleAlternates: alternates, knownTVDBID: knownTVDBID,
            knownProviderIDs: knownProviderIDs
        )
    }
}
