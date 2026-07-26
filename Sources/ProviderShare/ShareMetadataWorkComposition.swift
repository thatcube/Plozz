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
        concurrency: Int,
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
        budget: ShareMetadataBudget,
        local: some ShareLocalMetadataRunning,
        artwork: some ShareLocalArtworkProbing,
        external: some ShareExternalMetadataRunning,
        sharePermits: @Sendable @escaping () async -> Bool = { true },
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) async -> ShareEnrichmentSliceResult {
        ShareBackgroundActivity.enrichStarted()
        defer { ShareBackgroundActivity.enrichFinished() }
        // Two lanes, run CONCURRENTLY because they contend for different things:
        // the device lane reads sidecars and probes artwork over the share, while
        // the external lane makes internet requests. Running them in sequence made
        // the slower lane set the pace for both — after external work was given its
        // own (longer) allowance, artwork probing got roughly a seventh of its
        // former opportunities and stopped converging: 13,517 files pending with
        // ZERO validated, which is what silently removes every hero and backdrop,
        // since those placements require a validated probe.
        let deadline = ContinuousClock().now.advanced(by: budget.externalSliceDuration)
        async let deviceLane = runDeviceLane(
            accountKey: accountKey,
            budget: budget,
            deadline: deadline,
            local: local,
            artwork: artwork,
            sharePermits: sharePermits,
            isCancelled: isCancelled
        )
        async let externalLane = runExternalLane(
            accountKey: accountKey,
            budget: budget,
            local: local,
            external: external,
            isCancelled: isCancelled
        )
        let (device, remote) = await (deviceLane, externalLane)
        return ShareEnrichmentSliceResult(
            attempted: device.attempted + remote.attempted,
            hasMore: device.hasMore || remote.hasMore,
            retryAfter: device.retryAfter ?? remote.retryAfter,
            capacity: device.capacity
        )
    }

    /// Share-bound work: local sidecars and artwork probes. Keeps working for the
    /// whole slice at its own cadence — one bounded pass, then the configured idle
    /// gap — rather than taking a single pass and then idling for however long the
    /// metadata providers happen to take.
    private static func runDeviceLane(
        accountKey: String,
        budget: ShareMetadataBudget,
        deadline: ContinuousClock.Instant,
        local: some ShareLocalMetadataRunning,
        artwork: some ShareLocalArtworkProbing,
        sharePermits: @Sendable () async -> Bool,
        isCancelled: @Sendable () -> Bool
    ) async -> ShareEnrichmentSliceResult {
        let clock = ContinuousClock()
        var attempted = 0
        var hasMore = false
        var retryAfter: Duration?
        var measured: Duration = .zero
        var saturated = false
        var ranAnyPass = false

        while !isCancelled(), clock.now < deadline {
            // A scan owns share I/O; yielding to it is the point of the permit.
            guard await sharePermits() else { break }
            let passStart = clock.now
            let localResult = await local.resolvePendingSlice(
                maxItems: budget.itemsPerSlice,
                maxDuration: budget.sliceDuration
            )
            if isCancelled() { hasMore = true; break }
            let elapsed = passStart.duration(to: clock.now)
            let remaining = budget.sliceDuration > elapsed ? budget.sliceDuration - elapsed : .zero
            let remainingItems = max(0, budget.itemsPerSlice - localResult.attempted)
            var artworkResult = ShareEnrichmentSliceResult(attempted: 0, hasMore: false)
            if remaining > .zero, remainingItems > 0 {
                artworkResult = await artwork.resolvePendingSlice(
                    maxItems: remainingItems,
                    maxDuration: remaining
                )
            }
            let passItems = localResult.attempted + artworkResult.attempted
            ranAnyPass = true
            attempted += passItems
            measured = passStart.duration(to: clock.now)
            saturated = passItems >= budget.itemsPerSlice
            retryAfter = artworkResult.retryAfter ?? retryAfter
            hasMore = localResult.hasMore || artworkResult.hasMore
            BrowseDiagnostics.event(
                "device-lane \(accountKey) items=\(passItems) more=\(hasMore)"
            )
            // Out of work, or told to back off: stop rather than spin.
            if !hasMore || passItems == 0 { break }
            if isCancelled() { break }
            try? await Task.sleep(for: budget.delayBetweenSlices)
        }

        return ShareEnrichmentSliceResult(
            attempted: attempted,
            hasMore: hasMore || isCancelled(),
            retryAfter: retryAfter,
            // Only a real pass is evidence about this device. No pass — because a
            // scan holds the share, or the queue is empty — must not be read as
            // either slowness or headroom.
            capacity: ranAnyPass
                ? ShareMetadataCapacitySample(elapsed: measured, saturated: saturated)
                : nil
        )
    }

    /// Internet-bound work. Never gated on share availability: a metadata lookup
    /// cannot contend with a share scan, and gating it there left a 2,185-title
    /// library at 330 enriched.
    private static func runExternalLane(
        accountKey: String,
        budget: ShareMetadataBudget,
        local: some ShareLocalMetadataRunning,
        external: some ShareExternalMetadataRunning,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> ShareEnrichmentSliceResult {
        guard !isCancelled(),
              budget.externalSliceDuration > .zero,
              budget.externalItemsPerSlice > 0 else {
            return ShareEnrichmentSliceResult(attempted: 0, hasMore: true)
        }
        BrowseDiagnostics.event("enrich-slice+ \(accountKey)")
        let result = await external.enrichPendingSlice(
            maxItems: budget.externalItemsPerSlice,
            maxDuration: budget.externalSliceDuration,
            concurrency: budget.externalConcurrency,
            beforeResolve: { itemID in
                if isCancelled() { return false }
                let outcome = await local.resolveOne(itemID: itemID)
                return outcome != .transientFailure && outcome != .cancelled
            }
        )
        BrowseDiagnostics.event(
            "enrich-slice- \(accountKey) attempted=\(result.attempted) more=\(result.hasMore)"
        )
        return result
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
