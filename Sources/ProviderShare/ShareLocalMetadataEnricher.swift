import Foundation
import CoreModels
import MediaTransportCore

/// Bounded outcome of one urgent (opened-item) local resolution attempt.
enum ShareLocalMetadataOutcome: Sendable, Equatable {
    /// No pending/retryable sidecar associates with the item — nothing to do.
    case noPendingWork
    /// A sidecar was read, parsed, and materialized successfully.
    case resolved
    /// A sidecar reached a TERMINAL non-success outcome (malformed/oversized/
    /// ambiguous) — settled, will not be retried until its fingerprint changes.
    case terminal
    /// A transient transport failure. Retryable up to the bounded attempt cap.
    case transientFailure
    /// The work was cancelled at an await boundary (interrupt/suspend/removal).
    /// Distinct from `transientFailure`: it leaves the sidecar's fingerprint,
    /// status, and `local_attempts` UNCHANGED — cancellation burns no attempt — and
    /// must not fall through to external enrichment.
    case cancelled
}

/// Second, entirely LOCAL pass after a scan: reads changed NFO sidecars through
/// a dedicated `.metadata` transport session, parses them with `ShareNFOParser`,
/// and materializes deterministic per-field winners into `metadata_values` as
/// `localNFO`/`filename`-sourced candidates — independent of, and never
/// resetting, the existing external `ShareEnricher`'s version/attempts.
///
/// Ownership + scheduling: owned by `ShareCatalogCoordinator` alongside
/// `ShareEnricher`; runs ONLY from background metadata scheduling slices (never
/// synchronously from a Home/grid/detail read) and from the urgent opened-item
/// path, which promotes a pending/changed associated sidecar ahead of external
/// fast-track and awaits exactly one bounded outcome before releasing it (see
/// `ShareCatalogCoordinator`).
actor ShareLocalMetadataEnricher {
    /// Local materialization version — bump when the WINNER-SELECTION/combine
    /// logic changes (not the NFO field vocabulary alone), to re-materialize
    /// already-processed items. Deliberately independent of `ShareEnricher.version`.
    static let version = 1

    private let store: ShareCatalogStore
    private let sessionFactory: ShareTransportSessionFactory
    private var browser: ShareTransportBrowser?
    private var isRunning = false

    init(store: ShareCatalogStore, sessionFactory: @escaping ShareTransportSessionFactory) {
        self.store = store
        self.sessionFactory = sessionFactory
    }

    func close() async {
        await browser?.close()
        browser = nil
    }

    private func transportBrowser() -> ShareTransportBrowser {
        if let browser { return browser }
        let created = ShareTransportBrowser(role: .metadata, sessionFactory: sessionFactory)
        browser = created
        return created
    }

    /// Resolves one bounded scheduler slice of pending sidecars. Mirrors
    /// `ShareEnricher.enrichPendingSlice`'s shape so the coordinator can compose
    /// "local work first, external work with the remainder" from one slice budget.
    func resolvePendingSlice(
        maxItems: Int,
        maxDuration: Duration
    ) async -> ShareEnrichmentSliceResult {
        if isRunning { return ShareEnrichmentSliceResult(attempted: 0, hasMore: true) }
        isRunning = true
        defer { isRunning = false }

        let boundedMaxItems = max(1, maxItems)
        let rematerialized = await store.rematerializeOutdatedLocalMetadata(
            version: Self.version,
            limit: boundedMaxItems
        )
        let remaining = boundedMaxItems - rematerialized
        guard remaining > 0 else {
            return ShareEnrichmentSliceResult(attempted: rematerialized, hasMore: true)
        }
        let pending = await store.pendingLocalMetadataFiles(limit: remaining)
        guard !pending.isEmpty else {
            return ShareEnrichmentSliceResult(attempted: rematerialized, hasMore: false)
        }

        let clock = ContinuousClock()
        let started = clock.now
        var attempted = rematerialized
        for file in pending {
            if Task.isCancelled { break }
            let outcome = await process(file)
            if outcome == .cancelled { break }
            attempted += 1
            if started.duration(to: clock.now) >= maxDuration { break }
        }
        let processedSidecars = attempted - rematerialized
        let hasMore = Task.isCancelled
            || processedSidecars < pending.count
            || pending.count == remaining
        return ShareEnrichmentSliceResult(attempted: attempted, hasMore: hasMore)
    }

    /// Resolves the ONE sidecar (if any) associated with `itemID` right now —
    /// the urgent opened-item path. Performs exactly one bounded read+parse
    /// attempt (retries beyond that happen through the background slice pass,
    /// bounded by `ShareCatalogStore.maxLocalAttempts`), so the caller never
    /// hangs the opened item indefinitely regardless of outcome.
    func resolveOne(itemID: String) async -> ShareLocalMetadataOutcome {
        if Task.isCancelled { return .cancelled }
        if await store.rematerializeLocalMetadataIfNeeded(
            itemID: itemID,
            version: Self.version
        ) {
            return .resolved
        }
        guard let file = await store.pendingLocalMetadataFile(forItemID: itemID) else {
            return .noPendingWork
        }
        return await process(file)
    }

    // MARK: - Per-sidecar processing

    @discardableResult
    private func process(_ file: ShareCatalogStore.PendingLocalMetadataFile) async -> ShareLocalMetadataOutcome {
        if Task.isCancelled { return .cancelled }
        let facts = await store.localMetadataAssociationFacts(for: file)
        guard let itemID = ShareLocalMetadataAssociationPolicy.itemID(
            for: file.kind,
            associatedVideoRelPath: file.associatedVideoRelPath,
            facts: facts
        ) else {
            await store.markSidecarProcessed(
                relPath: file.relPath, status: "ambiguous",
                fingerprint: file.fingerprint, associatedItemID: nil
            )
            if let priorItemID = file.processedItemID {
                await store.materializeCachedLocalMetadata(itemID: priorItemID)
            }
            return .terminal
        }
        let affectedItemIDs = Set([itemID, file.processedItemID].compactMap { $0 })

        if file.size > Int64(ShareNFOParser.maxBytes) {
            await store.clearSidecarValueCache(relPath: file.relPath)
            await store.markSidecarProcessed(
                relPath: file.relPath, status: "oversized",
                fingerprint: file.fingerprint, associatedItemID: itemID
            )
            for itemID in affectedItemIDs {
                await store.materializeCachedLocalMetadata(itemID: itemID)
            }
            await store.writeLocalEnrichmentState(
                itemID: itemID, version: Self.version, attempts: 0
            )
            return .terminal
        }

        let data: Data
        do {
            if Task.isCancelled { return .cancelled }
            ShareBackgroundActivity.listStarted()
            defer { ShareBackgroundActivity.listFinished() }
            data = try await transportBrowser().readFile(
                file.relPath, maximumBytes: ShareNFOParser.maxBytes
            )
        } catch {
            // Cancellation leaves the sidecar UNCHANGED and burns no attempt — it is
            // not a transient transport failure. This covers a raw CancellationError,
            // a mapped MediaTransportError.cancelled (a session teardown can surface
            // it *after* the task's cancellation state is no longer observable), or
            // any error thrown while the task is still cancelled.
            if error is CancellationError
                || (error as? MediaTransportError) == .cancelled
                || Task.isCancelled {
                return .cancelled
            }
            await store.markSidecarTransientFailure(relPath: file.relPath)
            return .transientFailure
        }

        // A cancellation after the read but before any parse/persist mutation also
        // leaves the sidecar unchanged.
        if Task.isCancelled { return .cancelled }

        let outcome: ShareLocalMetadataOutcome
        switch ShareNFOParser.parse(data) {
        case .oversized:
            await store.clearSidecarValueCache(relPath: file.relPath)
            await store.markSidecarProcessed(
                relPath: file.relPath, status: "oversized",
                fingerprint: file.fingerprint, associatedItemID: itemID
            )
            outcome = .terminal
        case .malformed:
            await store.clearSidecarValueCache(relPath: file.relPath)
            await store.markSidecarProcessed(
                relPath: file.relPath, status: "malformed",
                fingerprint: file.fingerprint, associatedItemID: itemID
            )
            outcome = .terminal
        case .parsed(let parsed):
            guard await store.writeSidecarValueCache(
                relPath: file.relPath,
                fields: Self.encodeCache(parsed)
            ) else {
                await store.markSidecarTransientFailure(relPath: file.relPath)
                return .transientFailure
            }
            await store.markSidecarProcessed(
                relPath: file.relPath, status: "parsed",
                fingerprint: file.fingerprint, associatedItemID: itemID
            )
            outcome = .resolved
        }
        for itemID in affectedItemIDs {
            await store.materializeCachedLocalMetadata(itemID: itemID)
        }
        await store.writeLocalEnrichmentState(
            itemID: itemID, version: Self.version, attempts: 0
        )
        return outcome
    }

    /// JSON-encodes each present, VALIDATED field from a parsed NFO document,
    /// keyed by its final `MetadataField` — the per-sidecar cache
    /// (`local_metadata_file_values`) that survives independent of association.
    private static func encodeCache(_ parsed: ParsedNFO) -> [MetadataField: String] {
        var out: [MetadataField: String] = [:]
        func put(_ field: MetadataField, _ value: some Encodable) {
            guard let data = try? JSONEncoder().encode(value),
                  let json = String(data: data, encoding: .utf8) else { return }
            out[field] = json
        }
        if let title = parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            put(.title, title)
        }
        if let value = parsed.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            put(.originalTitle, value)
        }
        if let value = parsed.sortTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            put(.sortTitle, value)
        }
        if let year = parsed.year { put(.productionYear, year) }
        if !parsed.taglines.isEmpty { put(.taglines, parsed.taglines) }
        if let overview = parsed.overview, !overview.isEmpty { put(.overview, overview) }
        if !parsed.genres.isEmpty { put(.genres, parsed.genres) }
        if !parsed.studios.isEmpty { put(.studios, parsed.studios) }
        if !parsed.tags.isEmpty { put(.tags, parsed.tags) }
        if let runtime = parsed.runtimeSeconds, runtime > 0 { put(.runtime, runtime) }
        if let premiered = parsed.premiered { put(.premiereDate, premiered) }
        // airDate/seasonNumber/episodeNumber are EPISODE-only. Encode them only from
        // an `episodedetails` document so a `tvshow.nfo`/movie NFO carrying stray
        // season/episode/aired values can never persist episode-scoped fields (C1,
        // second defense boundary — the parser already root-gates acceptance).
        if parsed.root == .episodedetails {
            if let aired = parsed.aired { put(.airDate, aired) }
            if let season = parsed.season { put(.seasonNumber, season) }
            if let episode = parsed.episode { put(.episodeNumber, episode) }
        }
        if !parsed.ratings.isEmpty { put(.ratings, parsed.ratings) }

        // Provider ids: normalize + validate per namespace independently; the
        // `default` flag is only a tie-break among DUPLICATE values for the SAME
        // namespace, never permission to discard other namespaces.
        var byNamespace: [String: (value: String, isDefault: Bool)] = [:]
        for id in parsed.ids {
            guard let canonical = ShareMediaParser.canonicalExplicitID(
                namespace: id.rawNamespace, value: id.rawValue
            ) else { continue }
            if let existing = byNamespace[canonical.namespace] {
                if id.isDefault, !existing.isDefault {
                    byNamespace[canonical.namespace] = (canonical.value, true)
                }
            } else {
                byNamespace[canonical.namespace] = (canonical.value, id.isDefault)
            }
        }
        for (namespace, entry) in byNamespace {
            put(.providerID(namespace), entry.value)
        }
        return out
    }
}
