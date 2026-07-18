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
    static func runSlice(
        accountKey: String,
        maxItems: Int,
        maxDuration: Duration,
        local: some ShareLocalMetadataRunning,
        external: some ShareExternalMetadataRunning,
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
        BrowseDiagnostics.event("local-slice+ \(accountKey)")
        let localResult = await local.resolvePendingSlice(
            maxItems: maxItems,
            maxDuration: maxDuration
        )
        BrowseDiagnostics.event(
            "local-slice- \(accountKey) attempted=\(localResult.attempted) more=\(localResult.hasMore)"
        )
        // Cancellation after local work must not start an external resolver pass.
        if isCancelled() {
            return ShareEnrichmentSliceResult(attempted: localResult.attempted, hasMore: true)
        }
        let elapsed = sliceStart.duration(to: clock.now)
        let remaining = maxDuration > elapsed ? maxDuration - elapsed : .zero
        guard remaining > .zero else {
            return ShareEnrichmentSliceResult(attempted: localResult.attempted, hasMore: true)
        }
        BrowseDiagnostics.event("enrich-slice+ \(accountKey)")
        let result = await external.enrichPendingSlice(
            maxItems: maxItems,
            maxDuration: remaining,
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
            attempted: localResult.attempted + result.attempted,
            hasMore: localResult.hasMore || result.hasMore,
            retryAfter: result.retryAfter
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
