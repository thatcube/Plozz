import Foundation
import CoreModels

/// Local NFO/explicit-id metadata capability the work composition drives first.
///
/// `ShareLocalMetadataEnricher` conforms; tests substitute a fake to observe the
/// local-then-external ordering and cancellation fencing without a real store.
protocol ShareLocalMetadataRunning: Sendable {
    func resolvePendingSlice(maxItems: Int, maxDuration: Duration) async -> ShareEnrichmentSliceResult
    func resolveOne(itemID: String) async -> ShareLocalMetadataOutcome
}

/// Scheduler-only local artwork inspection. Unlike NFO work this intentionally
/// has no opened-item fast path, so Home/grid/detail reads never open artwork.
protocol ShareLocalArtworkProbing: Sendable {
    func resolvePendingSlice(maxItems: Int, maxDuration: Duration) async -> ShareEnrichmentSliceResult
}

/// External fill-missing enrichment capability the composition falls through to
/// with the slice budget remaining after local work.
///
/// `ShareEnricher` conforms; the provider order/selection it owns is unchanged.
protocol ShareExternalMetadataRunning: Sendable {
    func enrichPendingSlice(
        maxItems: Int,
        maxDuration: Duration,
        beforeResolve: (@Sendable (String) async -> Bool)?
    ) async -> ShareEnrichmentSliceResult
    func enrichOne(itemID: String) async
}

extension ShareLocalMetadataEnricher: ShareLocalMetadataRunning {}
extension ShareLocalArtworkProbeWorker: ShareLocalArtworkProbing {}
extension ShareEnricher: ShareExternalMetadataRunning {}

/// Composes "local NFO/explicit-id work first, then external fill-missing with the
/// remaining slice budget" for one account, fencing cancellation at every boundary.
///
/// Responsibility boundary: this seam owns ONLY the local→external ordering and its
/// cancellation fences. It holds no queue/admission state (the scheduler owns that),
/// performs no retry or provider-selection policy (the enrichers own that), and
/// never touches persistence directly. Extracting it keeps `ShareCatalogCoordinator`
/// a thin lifecycle owner and makes the ordering/cancellation contract directly
/// testable with fakes.
///
/// Invariant (finding A4): a cancelled slice/item never starts an external resolver
/// call after local work, and never lets a transient/cancelled local outcome fall
/// through to external. The enrichers additionally fence cancellation internally so
/// no local or external attempt is burned.
enum ShareMetadataWorkComposition {
    /// - Parameters:
    ///   - sharePermits: whether SHARE I/O may run right now (no scan holding
    ///     admission, no playback lease). Consulted per step rather than around
    ///     the whole slice, because the three kinds of work do not use the same
    ///     resource: local NFO reads and artwork probes go over the share, while
    ///     external metadata is an internet HTTP call that cannot contend with a
    ///     share scan at all. Gating the whole slice on share availability — the
    ///     previous behaviour — blocked TMDb lookups for the entire duration of
    ///     every scan, which is why a 2,185-title library sat at 330 enriched.
    ///   - externalReservation: fraction of the slice reserved for external work
    ///     so it can never be starved by a large local backlog. Strict local-first
    ///     priority meant 11,575 pending artwork probes had to drain — roughly 48
    ///     minutes of slices — before a single poster was fetched.
    static func runSlice(
        accountKey: String,
        maxItems: Int,
        maxDuration: Duration,
        local: some ShareLocalMetadataRunning,
        artwork: some ShareLocalArtworkProbing,
        external: some ShareExternalMetadataRunning,
        sharePermits: @Sendable () async -> Bool = { true },
        externalReservation: Double = 0.5,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) async -> ShareEnrichmentSliceResult {
        ShareBackgroundActivity.enrichStarted()
        defer { ShareBackgroundActivity.enrichFinished() }
        // Local work FIRST, then whatever slice budget remains for the existing
        // external pass — the minimum ordering needed so explicit ids/local fields
        // prevent an unnecessary fuzzy external lookup, without reordering external
        // providers.
        let clock = ContinuousClock()
        let sliceStart = clock.now
        // Reserve part of the budget for external work up front, so local work
        // cannot consume the slice and starve it.
        let reserved = max(1, Int((Double(maxItems) * externalReservation).rounded()))
        let localBudget = max(0, maxItems - reserved)
        let shareIsFree = await sharePermits()

        var localResult = ShareEnrichmentSliceResult(attempted: 0, hasMore: true)
        if shareIsFree, localBudget > 0 {
            BrowseDiagnostics.event("local-slice+ \(accountKey)")
            localResult = await local.resolvePendingSlice(
                maxItems: localBudget,
                maxDuration: maxDuration
            )
        } else {
            BrowseDiagnostics.event("local-slice~ \(accountKey) shareBusy=\(!shareIsFree)")
        }
        BrowseDiagnostics.event(
            "local-slice- \(accountKey) attempted=\(localResult.attempted) more=\(localResult.hasMore)"
        )
        // Local NFO and local artwork share one scheduler-slice item/time budget.
        if isCancelled() {
            return ShareEnrichmentSliceResult(attempted: localResult.attempted, hasMore: true)
        }
        let elapsed = sliceStart.duration(to: clock.now)
        let remaining = maxDuration > elapsed ? maxDuration - elapsed : .zero
        let remainingItems = max(0, localBudget - localResult.attempted)
        var artworkResult = ShareEnrichmentSliceResult(attempted: 0, hasMore: true)
        if shareIsFree, remaining > .zero, remainingItems > 0 {
            BrowseDiagnostics.event("artwork-slice+ \(accountKey)")
            artworkResult = await artwork.resolvePendingSlice(
                maxItems: remainingItems,
                maxDuration: remaining
            )
        }
        BrowseDiagnostics.event(
            "artwork-slice- \(accountKey) attempted=\(artworkResult.attempted) more=\(artworkResult.hasMore)"
        )
        if isCancelled() {
            return ShareEnrichmentSliceResult(
                attempted: localResult.attempted + artworkResult.attempted,
                hasMore: true
            )
        }
        let afterArtwork = sliceStart.duration(to: clock.now)
        let externalDuration = maxDuration > afterArtwork ? maxDuration - afterArtwork : .zero
        // The reservation, plus anything local/artwork left unused. When the share
        // is busy that is the WHOLE slice — the scan and the metadata fetch use
        // different resources, so there is no reason for one to idle the other.
        let externalItems = maxItems - localResult.attempted - artworkResult.attempted
        guard externalDuration > .zero, externalItems > 0 else {
            return ShareEnrichmentSliceResult(
                attempted: localResult.attempted + artworkResult.attempted,
                hasMore: true,
                retryAfter: artworkResult.retryAfter
            )
        }
        BrowseDiagnostics.event("enrich-slice+ \(accountKey)")
        let result = await external.enrichPendingSlice(
            maxItems: externalItems,
            maxDuration: externalDuration,
            beforeResolve: { itemID in
                if isCancelled() { return false }
                let outcome = await local.resolveOne(itemID: itemID)
                return outcome != .transientFailure && outcome != .cancelled
            }
        )
        BrowseDiagnostics.event(
            "enrich-slice- \(accountKey) attempted=\(result.attempted) more=\(result.hasMore)"
        )
        return ShareEnrichmentSliceResult(
            attempted: localResult.attempted + artworkResult.attempted + result.attempted,
            hasMore: localResult.hasMore || artworkResult.hasMore || result.hasMore,
            retryAfter: artworkResult.retryAfter ?? result.retryAfter
        )
    }

    static func runItem(
        accountKey: String,
        itemID: String,
        local: some ShareLocalMetadataRunning,
        external: some ShareExternalMetadataRunning,
        isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    ) async {
        ShareBackgroundActivity.enrichStarted()
        defer { ShareBackgroundActivity.enrichFinished() }
        // Promote the item's own pending/changed local NFO first and await its
        // bounded outcome — so freshly-persisted local ids are visible to the
        // external request below (and a provider with exact-id support can skip
        // fuzzy title search) — before ever falling through to the external
        // fast-track.
        BrowseDiagnostics.event("local-item+ \(accountKey)")
        let localOutcome = await local.resolveOne(itemID: itemID)
        BrowseDiagnostics.event("local-item- \(accountKey)")
        // A transient failure retries later; a cancellation must not start external
        // work. Terminal/resolved/no-work outcomes fall through unchanged.
        guard localOutcome != .transientFailure,
              localOutcome != .cancelled,
              !isCancelled() else { return }
        BrowseDiagnostics.event("enrich-item+ \(accountKey)")
        await external.enrichOne(itemID: itemID)
        BrowseDiagnostics.event("enrich-item- \(accountKey)")
    }
}
