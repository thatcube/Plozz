import Foundation
import XCTest
@testable import ProviderShare

/// Verifies the local→external ordering seam (`ShareMetadataWorkComposition`) fences
/// cancellation at every boundary: a cancelled slice/item never starts an external
/// resolver pass after local work, and a transient/cancelled local outcome never
/// falls through to external (finding A4). Uses fakes and an injected `isCancelled`
/// so the boundaries are deterministic.
final class ShareMetadataWorkCompositionTests: XCTestCase {
    /// A one-way latch. The lanes run concurrently, so a cancellation fixture
    /// that counts `isCancelled` calls is order-dependent and flaky; this lets the
    /// fake trip cancellation at the exact boundary under test instead.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        /// Returns true starting from the Nth call (1-based).
        func trueFrom(_ n: Int) -> Bool {
            lock.withLock {
                count += 1
                return count >= n
            }
        }
    }

    private actor FakeLocal: ShareLocalMetadataRunning {
        private(set) var sliceCalls = 0
        private(set) var resolveOneCalls = 0
        /// The budget the composition actually offered, so a test can assert the
        /// reservation without depending on what the fake chooses to consume.
        private(set) var lastSliceMaxItems = 0
        private let sliceResult: ShareEnrichmentSliceResult
        private let oneOutcome: ShareLocalMetadataOutcome

        init(
            sliceResult: ShareEnrichmentSliceResult = .init(attempted: 1, hasMore: false),
            oneOutcome: ShareLocalMetadataOutcome = .resolved
        ) {
            self.sliceResult = sliceResult
            self.oneOutcome = oneOutcome
        }

        func resolvePendingSlice(maxItems: Int, maxDuration: Duration) async -> ShareEnrichmentSliceResult {
            sliceCalls += 1
            lastSliceMaxItems = maxItems
            return sliceResult
        }

        func resolveOne(itemID: String) async -> ShareLocalMetadataOutcome {
            resolveOneCalls += 1
            return oneOutcome
        }
    }

    private actor FakeExternal: ShareExternalMetadataRunning {
        private(set) var sliceCalls = 0
        private(set) var itemCalls = 0
        private(set) var beforeResolveResults: [Bool] = []
        private(set) var lastConcurrency = 0
        private(set) var lastMaxItems = 0
        private let invokeBeforeResolve: Bool
        private let latchBeforeResolve: Latch?

        init(invokeBeforeResolve: Bool = false, latchBeforeResolve: Latch? = nil) {
            self.invokeBeforeResolve = invokeBeforeResolve
            self.latchBeforeResolve = latchBeforeResolve
        }

        func enrichPendingSlice(
            maxItems: Int,
            maxDuration: Duration,
            concurrency: Int,
            beforeResolve: (@Sendable (String) async -> Bool)?
        ) async -> ShareEnrichmentSliceResult {
            sliceCalls += 1
            lastConcurrency = concurrency
            lastMaxItems = maxItems
            if invokeBeforeResolve, let beforeResolve {
                latchBeforeResolve?.set()
                beforeResolveResults.append(await beforeResolve("item-1"))
            }
            return .init(attempted: 1, hasMore: false)
        }

        func enrichOne(itemID: String) async {
            itemCalls += 1
        }
    }

    private actor FakeArtwork: ShareLocalArtworkProbing {
        private(set) var sliceCalls = 0
        private let result: ShareEnrichmentSliceResult

        init(result: ShareEnrichmentSliceResult = .init(attempted: 0, hasMore: false)) {
            self.result = result
        }

        func resolvePendingSlice(maxItems: Int, maxDuration: Duration) async -> ShareEnrichmentSliceResult {
            sliceCalls += 1
            return result
        }
    }

    // MARK: - runSlice

    func testRunSliceRunsExternalWhenNotCancelled() async {
        let local = FakeLocal(sliceResult: .init(attempted: 2, hasMore: false))
        let artwork = FakeArtwork()
        let external = FakeExternal()
        let result = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(items: 10, sliceDuration: .seconds(1)),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { false }
        )
        let localSlices = await local.sliceCalls
        let externalSlices = await external.sliceCalls
        XCTAssertEqual(localSlices, 1)
        XCTAssertEqual(externalSlices, 1, "external must run with the remaining budget when not cancelled")
        XCTAssertEqual(result.attempted, 3, "attempts combine local + external")
    }

    /// An already-cancelled slice starts no work at all. The lanes run
    /// concurrently now, so cancellation is checked before either begins rather
    /// than only between them.
    func testACancelledSliceStartsNeitherLane() async {
        let local = FakeLocal(sliceResult: .init(attempted: 2, hasMore: false))
        let artwork = FakeArtwork()
        let external = FakeExternal()
        let result = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(items: 10, sliceDuration: .milliseconds(20)),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { true }
        )
        let localSlices = await local.sliceCalls
        let externalSlices = await external.sliceCalls
        XCTAssertEqual(localSlices, 0, "cancellation must not start device work")
        XCTAssertEqual(externalSlices, 0, "cancellation must not start an external pass")
        XCTAssertTrue(result.hasMore, "a cancelled slice reports more work remaining")
    }

    func testRunSliceBeforeResolveSkipsLocalOnCancellation() async {
        // Cancellation trips exactly when `beforeResolve` fires, proving the
        // per-item boundary is fenced.
        let latch = Latch()
        let local = FakeLocal()
        let artwork = FakeArtwork()
        let external = FakeExternal(invokeBeforeResolve: true, latchBeforeResolve: latch)
        _ = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(items: 10, sliceDuration: .milliseconds(20)),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { latch.isSet }
        )
        let externalSlices = await external.sliceCalls
        let beforeResults = await external.beforeResolveResults
        let resolveOneCalls = await local.resolveOneCalls
        XCTAssertEqual(externalSlices, 1, "the external pass started before the cancellation")
        XCTAssertEqual(beforeResults, [false], "beforeResolve short-circuits to false on cancellation")
        XCTAssertEqual(resolveOneCalls, 0, "a cancelled beforeResolve must not call local resolveOne")
    }

    /// Local NFO and artwork still share ONE budget between them — but that budget
    /// is now the non-reserved part of the slice, not the whole thing.
    ///
    /// The contract deliberately changed. Strict local-first priority meant a
    /// large local backlog starved external metadata indefinitely: a real library
    /// with 11,575 pending artwork probes would have had to drain them all — on
    /// the order of an hour of slices — before one poster was fetched. External
    /// work now holds a reservation it cannot be squeezed out of.
    func testExternalIsNotStarvedByAnEndlessLocalBacklog() async {
        // The local lane always reports more work — the real shape of a library
        // with thousands of pending artwork probes.
        let local = FakeLocal(sliceResult: .init(attempted: 6, hasMore: true))
        let artwork = FakeArtwork(result: .init(attempted: 4, hasMore: true))
        let external = FakeExternal()
        let result = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(
                items: 10,
                sliceDuration: .milliseconds(20),
                externalSliceDuration: .milliseconds(20)
            ),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { false }
        )
        // No reservation is needed any more: the lanes contend for different
        // resources, so they run at the same time and neither can squeeze the
        // other out.
        let externalSlices = await external.sliceCalls
        XCTAssertEqual(externalSlices, 1, "external must run alongside local work")
        let localMax = await local.lastSliceMaxItems
        XCTAssertEqual(localMax, 10, "the device lane gets the whole item budget")
        XCTAssertTrue(result.hasMore)
    }

    /// The regression that removed every hero and backdrop: once external work had
    /// its own longer allowance, a single sequential local pass per slice meant
    /// artwork probing ran a seventh as often and never converged (13,517 files
    /// pending, ZERO validated — and `homeHero`/`detailBackdrop` require a
    /// validated probe). The device lane must keep working for the whole slice.
    func testDeviceLaneKeepsWorkingForTheWholeSlice() async {
        let local = FakeLocal(sliceResult: .init(attempted: 1, hasMore: true))
        let artwork = FakeArtwork(result: .init(attempted: 1, hasMore: true))
        let external = FakeExternal()
        _ = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(
                items: 4,
                sliceDuration: .milliseconds(5),
                externalSliceDuration: .milliseconds(60)
            ),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { false }
        )
        let passes = await local.sliceCalls
        XCTAssertGreaterThan(passes, 1, "device work must not stop after one pass")
    }

    /// A share scan holds share I/O, but an external metadata lookup is an
    /// internet call — it must keep running. Blocking it was why enrichment stalled
    /// for the entire duration of every scan.
    func testExternalStillRunsWhileShareIOIsBusy() async {
        let local = FakeLocal(sliceResult: .init(attempted: 0, hasMore: true))
        let artwork = FakeArtwork(result: .init(attempted: 0, hasMore: true))
        let external = FakeExternal()
        _ = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(items: 10, sliceDuration: .seconds(1)),
            local: local,
            artwork: artwork,
            external: external,
            sharePermits: { false },
            isCancelled: { false }
        )
        let localSlices = await local.sliceCalls
        let artworkSlices = await artwork.sliceCalls
        let externalSlices = await external.sliceCalls
        XCTAssertEqual(localSlices, 0, "share I/O must not run while the share is busy")
        XCTAssertEqual(artworkSlices, 0, "share I/O must not run while the share is busy")
        XCTAssertEqual(externalSlices, 1, "internet work does not contend with the share")
    }

    // MARK: - runItem

    func testRunItemRunsExternalOnResolvedLocalOutcome() async {
        let local = FakeLocal(oneOutcome: .resolved)
        let external = FakeExternal()
        await ShareMetadataWorkComposition.runItem(
            accountKey: "a",
            itemID: "item-1",
            local: local,
            external: external,
            isCancelled: { false }
        )
        let resolveOneCalls = await local.resolveOneCalls
        let itemCalls = await external.itemCalls
        XCTAssertEqual(resolveOneCalls, 1)
        XCTAssertEqual(itemCalls, 1, "a resolved local outcome falls through to external fill-missing")
    }

    func testRunItemSkipsExternalOnCancellation() async {
        let local = FakeLocal(oneOutcome: .resolved)
        let external = FakeExternal()
        await ShareMetadataWorkComposition.runItem(
            accountKey: "a",
            itemID: "item-1",
            local: local,
            external: external,
            isCancelled: { true }
        )
        let itemCalls = await external.itemCalls
        XCTAssertEqual(itemCalls, 0, "cancellation after local must not start external item work")
    }

    func testRunItemSkipsExternalOnTransientLocalOutcome() async {
        let local = FakeLocal(oneOutcome: .transientFailure)
        let external = FakeExternal()
        await ShareMetadataWorkComposition.runItem(
            accountKey: "a",
            itemID: "item-1",
            local: local,
            external: external,
            isCancelled: { false }
        )
        let itemCalls = await external.itemCalls
        XCTAssertEqual(itemCalls, 0, "a transient local failure retries later, not via external")
    }

    func testRunItemSkipsExternalOnCancelledLocalOutcome() async {
        let local = FakeLocal(oneOutcome: .cancelled)
        let external = FakeExternal()
        await ShareMetadataWorkComposition.runItem(
            accountKey: "a",
            itemID: "item-1",
            local: local,
            external: external,
            isCancelled: { false }
        )
        let itemCalls = await external.itemCalls
        XCTAssertEqual(itemCalls, 0, "a cancelled local outcome must not fall through to external")
    }

    /// External lookups are HTTP round trips, so the slice must hand the enricher
    /// its concurrency width — resolving them one at a time made throughput the
    /// reciprocal of provider latency (measured on device: `attempted=1` against a
    /// 13-item allowance).
    func testExternalWorkReceivesTheBudgetsConcurrencyWidth() async {
        let local = FakeLocal(sliceResult: .init(attempted: 0, hasMore: false))
        let artwork = FakeArtwork()
        let external = FakeExternal()
        _ = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(items: 10, sliceDuration: .seconds(1), externalConcurrency: 6),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { false }
        )
        let width = await external.lastConcurrency
        XCTAssertEqual(width, 6)
    }

    /// The device-bound portion is the only capacity evidence a slice produces.
    /// Reporting the whole slice would let provider latency shrink the budget,
    /// which on device throttled a healthy M1 iPad from 32 items to 6.
    func testCapacitySampleCoversOnlyDeviceBoundWork() async {
        let local = FakeLocal(sliceResult: .init(attempted: 10, hasMore: false))
        let artwork = FakeArtwork()
        let external = FakeExternal()
        let result = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(
                items: 10,
                sliceDuration: .milliseconds(20),
                externalSliceDuration: .milliseconds(20)
            ),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { false }
        )
        XCTAssertNotNil(result.capacity)
        // The device lane used its whole item allowance, which is what "saturated"
        // means — the signal that there may be headroom to grow.
        XCTAssertEqual(result.capacity?.saturated, true)
    }

    /// When the share is busy the slice does no device-bound work at all, so it
    /// must report no capacity sample rather than a misleadingly fast one.
    func testNoCapacitySampleWhenShareWorkWasSkipped() async {
        let local = FakeLocal(sliceResult: .init(attempted: 0, hasMore: false))
        let artwork = FakeArtwork()
        let external = FakeExternal()
        let result = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(items: 10, sliceDuration: .seconds(1)),
            local: local,
            artwork: artwork,
            external: external,
            sharePermits: { false },
            isCancelled: { false }
        )
        XCTAssertNil(result.capacity)
    }

    /// The device lane's adapted budget must not govern the network lane. They
    /// contend for different resources, so letting a slow share shrink the number
    /// of internet requests throttles work the share has nothing to do with.
    func testExternalItemBudgetIsIndependentOfTheAdaptedDeviceBudget() async {
        let local = FakeLocal(sliceResult: .init(attempted: 0, hasMore: false))
        let artwork = FakeArtwork()
        let external = FakeExternal()
        _ = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            budget: .testing(
                items: 4,                 // device lane shrunk to its floor
                sliceDuration: .milliseconds(20),
                externalItemsPerSlice: 48,
                externalSliceDuration: .milliseconds(20)
            ),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { false }
        )
        let offered = await external.lastMaxItems
        XCTAssertEqual(offered, 48, "external work must use its own allowance")
    }
}
