import Foundation
import XCTest
@testable import ProviderShare

/// Verifies the local→external ordering seam (`ShareMetadataWorkComposition`) fences
/// cancellation at every boundary: a cancelled slice/item never starts an external
/// resolver pass after local work, and a transient/cancelled local outcome never
/// falls through to external (finding A4). Uses fakes and an injected `isCancelled`
/// so the boundaries are deterministic.
final class ShareMetadataWorkCompositionTests: XCTestCase {
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
        private let invokeBeforeResolve: Bool

        init(invokeBeforeResolve: Bool = false) {
            self.invokeBeforeResolve = invokeBeforeResolve
        }

        func enrichPendingSlice(
            maxItems: Int,
            maxDuration: Duration,
            beforeResolve: (@Sendable (String) async -> Bool)?
        ) async -> ShareEnrichmentSliceResult {
            sliceCalls += 1
            if invokeBeforeResolve, let beforeResolve {
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
            maxItems: 10,
            maxDuration: .seconds(1),
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

    func testRunSliceSkipsExternalWhenCancelledAfterLocal() async {
        let local = FakeLocal(sliceResult: .init(attempted: 2, hasMore: false))
        let artwork = FakeArtwork()
        let external = FakeExternal()
        let result = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            maxItems: 10,
            maxDuration: .seconds(1),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { true }
        )
        let localSlices = await local.sliceCalls
        let externalSlices = await external.sliceCalls
        XCTAssertEqual(localSlices, 1, "local work still runs")
        XCTAssertEqual(externalSlices, 0, "cancellation after local must not start an external pass")
        XCTAssertTrue(result.hasMore, "a cancelled slice reports more work remaining")
        XCTAssertEqual(result.attempted, 2, "only local attempts are reported")
    }

    func testRunSliceBeforeResolveSkipsLocalOnCancellation() async {
        // isCancelled is false at the post-NFO and post-artwork gates (calls 1–2)
        // but true when beforeResolve fires (call 3), proving the per-item boundary
        // is fenced too.
        let flag = LockedFlag()
        let local = FakeLocal()
        let artwork = FakeArtwork()
        let external = FakeExternal(invokeBeforeResolve: true)
        _ = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            maxItems: 10,
            maxDuration: .seconds(1),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { flag.trueFrom(3) }
        )
        let externalSlices = await external.sliceCalls
        let beforeResults = await external.beforeResolveResults
        let resolveOneCalls = await local.resolveOneCalls
        XCTAssertEqual(externalSlices, 1, "the external pass started before the cancellation")
        XCTAssertEqual(beforeResults, [false], "beforeResolve short-circuits to false on cancellation")
        XCTAssertEqual(resolveOneCalls, 0, "a cancelled beforeResolve must not call local resolveOne")
    }

    func testLocalArtworkAndNFOShareTheSchedulerItemBudget() async {
        let local = FakeLocal(sliceResult: .init(attempted: 6, hasMore: false))
        let artwork = FakeArtwork(result: .init(attempted: 4, hasMore: false))
        let external = FakeExternal()
        let result = await ShareMetadataWorkComposition.runSlice(
            accountKey: "a",
            maxItems: 10,
            maxDuration: .seconds(1),
            local: local,
            artwork: artwork,
            external: external,
            isCancelled: { false }
        )
        XCTAssertEqual(result.attempted, 10)
        XCTAssertTrue(result.hasMore, "external work must remain scheduled when local artwork exhausts the shared slice")
        let externalSlices = await external.sliceCalls
        XCTAssertEqual(externalSlices, 0)
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
}
