import XCTest
@testable import CoreModels

/// Covers the Track A lane: the provider protocol, open-time source SELECTION
/// (priority + availability + empty-skip fallthrough), and the default-OFF
/// Swift→C marshal coordinator.
final class KeyframeTableSourceTests: XCTestCase {

    // A stub source with controllable kind / availability / table.
    private struct StubSource: KeyframeTableSource {
        let kind: KeyframeSourceKind
        var available: Bool = true
        var table: KeyframeTable?
        func isAvailable() -> Bool { available }
        func loadKeyframeTable() -> KeyframeTable? { table }
    }

    private struct RecordingSink: FullVODKeyframeSink {
        let accept: Bool
        final class Box { var received: KeyframeTable?; var calls = 0 }
        let box = Box()
        func applyFullVODKeyframes(_ table: KeyframeTable) -> Bool {
            box.calls += 1
            box.received = table
            return accept
        }
    }

    private func table(_ times: [Double], _ duration: Double, _ offs: [Int64]? = nil) -> KeyframeTable {
        KeyframeTable.normalized(times: times, byteOffsets: offs, duration: duration)
    }

    // MARK: - Kind priority

    func testKindOrderingIsCuesFirst() {
        XCTAssertLessThan(KeyframeSourceKind.liveCues, .noCuesWalk)
        XCTAssertLessThan(KeyframeSourceKind.noCuesWalk, .persistedCache)
        XCTAssertLessThan(KeyframeSourceKind.persistedCache, .serverEndpoint)
        // CaseIterable order matches priority.
        XCTAssertEqual(KeyframeSourceKind.allCases,
                       [.liveCues, .noCuesWalk, .persistedCache, .serverEndpoint])
    }

    // MARK: - Selection

    func testResolvePicksHighestPriorityAvailableSource() {
        let cues = StubSource(kind: .liveCues, table: table([0, 6, 12], 20, [100, 400, 800]))
        let cache = StubSource(kind: .persistedCache, table: table([0, 5, 10], 20))
        // Provide out of priority order; selector must still pick Cues.
        let provider = KeyframeTableProvider(sources: [cache, cues])
        let result = provider.resolve()
        XCTAssertEqual(result?.kind, .liveCues)
        XCTAssertEqual(result?.table.times, [0, 6, 12])
        XCTAssertEqual(result?.table.byteOffsets, [100, 400, 800])
    }

    func testResolveFallsThroughWhenHigherPriorityUnavailable() {
        let cues = StubSource(kind: .liveCues, available: false, table: table([0, 6], 12, [1, 2]))
        let walk = StubSource(kind: .noCuesWalk, table: table([0, 4, 8], 12))
        let provider = KeyframeTableProvider(sources: [cues, walk])
        let result = provider.resolve()
        XCTAssertEqual(result?.kind, .noCuesWalk)
        XCTAssertNil(result?.table.byteOffsets) // walk source carries no offsets
    }

    func testResolveSkipsAvailableButEmptyTable() {
        // Available, but yields an empty table (e.g. Cues element present but 0 usable points).
        let cues = StubSource(kind: .liveCues, table: table([], 12))
        let cache = StubSource(kind: .persistedCache, table: table([0, 6], 12))
        let provider = KeyframeTableProvider(sources: [cues, cache])
        XCTAssertEqual(provider.resolve()?.kind, .persistedCache)
    }

    func testResolveSkipsSourceReturningNil() {
        let cues = StubSource(kind: .liveCues, table: nil)
        let cache = StubSource(kind: .persistedCache, table: table([0, 6], 12))
        let provider = KeyframeTableProvider(sources: [cues, cache])
        XCTAssertEqual(provider.resolve()?.kind, .persistedCache)
    }

    func testResolveReturnsNilWhenNoUsableSource() {
        let cues = StubSource(kind: .liveCues, available: false, table: nil)
        let cache = StubSource(kind: .persistedCache, table: table([], 0))
        let provider = KeyframeTableProvider(sources: [cues, cache])
        XCTAssertNil(provider.resolve())
    }

    // MARK: - Coordinator (default-OFF marshal)

    func testCoordinatorDisabledByDefaultDoesNothing() {
        let cues = StubSource(kind: .liveCues, table: table([0, 6], 12, [1, 2]))
        let sink = RecordingSink(accept: true)
        let coordinator = FullVODKeyframeCoordinator(
            provider: KeyframeTableProvider(sources: [cues]),
            sink: sink
        )
        XCTAssertFalse(coordinator.isEnabled) // shipped default
        XCTAssertEqual(coordinator.activateIfAvailable(), .disabled)
        XCTAssertEqual(sink.box.calls, 0) // engine never touched
    }

    func testCoordinatorEnabledMarshalsChosenTable() {
        let cues = StubSource(kind: .liveCues, table: table([0, 6, 12], 18, [10, 20, 30]))
        let sink = RecordingSink(accept: true)
        let coordinator = FullVODKeyframeCoordinator(
            provider: KeyframeTableProvider(sources: [cues]),
            sink: sink,
            isEnabled: true
        )
        XCTAssertEqual(coordinator.activateIfAvailable(), .applied(.liveCues))
        XCTAssertEqual(sink.box.calls, 1)
        XCTAssertEqual(sink.box.received?.times, [0, 6, 12])
        XCTAssertEqual(sink.box.received?.byteOffsets, [10, 20, 30])
    }

    func testCoordinatorEnabledNoSourceReportsNoSource() {
        let cues = StubSource(kind: .liveCues, available: false, table: nil)
        let sink = RecordingSink(accept: true)
        let coordinator = FullVODKeyframeCoordinator(
            provider: KeyframeTableProvider(sources: [cues]),
            sink: sink,
            isEnabled: true
        )
        XCTAssertEqual(coordinator.activateIfAvailable(), .noSource)
        XCTAssertEqual(sink.box.calls, 0)
    }

    func testCoordinatorEngineRejectionReportsRejected() {
        let cues = StubSource(kind: .liveCues, table: table([0, 6], 12, [1, 2]))
        let sink = RecordingSink(accept: false) // engine refuses the table
        let coordinator = FullVODKeyframeCoordinator(
            provider: KeyframeTableProvider(sources: [cues]),
            sink: sink,
            isEnabled: true
        )
        XCTAssertEqual(coordinator.activateIfAvailable(), .rejected(.liveCues))
        XCTAssertEqual(sink.box.calls, 1)
    }

    // MARK: - CuesKeyframeProvider as the first concrete conformer

    func testCuesProviderConformsAsLiveCuesSource() {
        let summary = MatroskaSummary(
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            durationTicks: 7_200_000,
            cues: [
                MatroskaCuePoint(timeTicks: 0, clusterPosition: 5_000),
                MatroskaCuePoint(timeTicks: 6_000, clusterPosition: 4_000_000),
                MatroskaCuePoint(timeTicks: 12_000, clusterPosition: 8_000_000)
            ]
        )
        let source: any KeyframeTableSource = CuesKeyframeProvider(summary: summary)
        XCTAssertEqual(source.kind, .liveCues)
        XCTAssertTrue(source.isAvailable())
        let loaded = source.loadKeyframeTable()
        XCTAssertEqual(loaded?.times, [0, 6, 12])
        XCTAssertEqual(loaded?.byteOffsets, [5_000, 4_000_000, 8_000_000])
    }

    func testCuesProviderUnavailableWhenNoCues() {
        let summary = MatroskaSummary(
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            durationTicks: 100_000,
            cues: []
        )
        let source = CuesKeyframeProvider(summary: summary)
        XCTAssertFalse(source.isAvailable())
        XCTAssertNil(source.loadKeyframeTable())
    }

    func testProviderSelectsRealCuesOverCache() {
        let summary = MatroskaSummary(
            segmentDataOffset: 0,
            timestampScaleNs: 1_000_000,
            durationTicks: 30_000,
            cues: [
                MatroskaCuePoint(timeTicks: 0, clusterPosition: 100),
                MatroskaCuePoint(timeTicks: 5_000, clusterPosition: 9_000)
            ]
        )
        let liveCues = CuesKeyframeProvider(summary: summary)
        let cache = StubSource(kind: .persistedCache, table: table([0, 10, 20], 30))
        let provider = KeyframeTableProvider(sources: [cache, liveCues])
        let result = provider.resolve()
        XCTAssertEqual(result?.kind, .liveCues)
        XCTAssertEqual(result?.table.byteOffsets, [100, 9_000]) // exact, byte-bearing
    }
}
