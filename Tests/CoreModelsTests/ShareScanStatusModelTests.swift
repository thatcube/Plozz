import XCTest
@testable import CoreModels

/// Coverage for the media-share scan status model that drives the Home
/// "Updating library…" banner and the Settings last-scanned line.
@MainActor
final class ShareScanStatusModelTests: XCTestCase {
    func testBusyWhileScanningThenClearsOnFinish() {
        let model = ShareScanStatusModel()
        XCTAssertFalse(model.isAnyBusy)

        model.scanStarted(shareID: "s1", name: "Brando NAS")
        XCTAssertTrue(model.isAnyBusy)
        XCTAssertEqual(model.busyShareNames, ["Brando NAS"])
        XCTAssertNil(model.state(forShareID: "s1")?.lastScanAt)

        model.scanFinished(shareID: "s1")
        XCTAssertFalse(model.isAnyBusy)
        XCTAssertNotNil(model.state(forShareID: "s1")?.lastScanAt, "finishing stamps a last-scanned time")
    }

    func testEnrichKeepsBusyAfterScanFinishes() {
        let model = ShareScanStatusModel()
        model.scanStarted(shareID: "s1", name: "NAS")
        model.scanFinished(shareID: "s1")
        XCTAssertFalse(model.isAnyBusy)

        model.enrichStarted(shareID: "s1", total: 100)
        XCTAssertTrue(model.isAnyBusy, "enrichment keeps the indicator up (art/details still resolving)")
        model.enrichFinished(shareID: "s1")
        XCTAssertFalse(model.isAnyBusy)
    }

    func testEnrichProgressTracksDoneAndFraction() {
        let model = ShareScanStatusModel()
        model.scanStarted(shareID: "s1", name: "NAS")
        model.scanFinished(shareID: "s1")
        model.enrichStarted(shareID: "s1", total: 200)
        model.enrichProgress(shareID: "s1", done: 50)

        let state = model.state(forShareID: "s1")
        XCTAssertEqual(state?.enrichDone, 50)
        XCTAssertEqual(state?.enrichTotal, 200)
        XCTAssertEqual(state?.enrichFraction, 0.25)
        XCTAssertEqual(state?.phase, "Updating artwork")
        // `done` is left-padded (figure space) to the width of `total` for a stable
        // pill width — 50 → "\u{2007}50" against a 3-digit total.
        XCTAssertEqual(state?.progressDetail, "\u{2007}50 of 200")

        model.enrichFinished(shareID: "s1")
        XCTAssertNil(model.state(forShareID: "s1")?.enrichFraction, "finished clears the pass totals")
    }

    func testEnrichProgressDetailStaysFixedWidthAsCounterClimbs() {
        // The whole point of the padding: every "N of M" string is the same length
        // through a pass, so the pill can't jitter as the counter flies.
        let model = ShareScanStatusModel()
        model.scanStarted(shareID: "s1", name: "NAS")
        model.scanFinished(shareID: "s1")
        model.enrichStarted(shareID: "s1", total: 900)

        var widths = Set<Int>()
        for done in [1, 9, 42, 137, 900] {
            model.enrichProgress(shareID: "s1", done: done)
            if let detail = model.state(forShareID: "s1")?.progressDetail {
                widths.insert(detail.count)
            }
        }
        XCTAssertEqual(widths.count, 1, "every progress string is the same width for the pass")
    }

    func testBusyStatesAndSharedNameLookup() {
        let model = ShareScanStatusModel()
        model.scanStarted(shareID: "s1", name: "Brando NAS")
        model.scanProgress(shareID: "s1", itemsFound: 1234)
        XCTAssertEqual(model.busyStates.map(\.name), ["Brando NAS"])
        XCTAssertEqual(model.busyStates.first?.progressDetail, "1,234 items")
        XCTAssertTrue(model.isBusy(shareNamed: "Brando NAS"))
        XCTAssertFalse(model.isBusy(shareNamed: "Other"))
        XCTAssertFalse(model.isBusy(shareNamed: ""), "an empty name never matches")

        model.scanFinished(shareID: "s1")
        XCTAssertFalse(model.isBusy(shareNamed: "Brando NAS"), "no longer busy once the scan finishes")
    }

    func testProgressUpdatesItemCount() {
        let model = ShareScanStatusModel()
        model.scanStarted(shareID: "s1", name: "NAS")
        model.scanProgress(shareID: "s1", itemsFound: 42)
        XCTAssertEqual(model.state(forShareID: "s1")?.itemsFound, 42)
    }

    func testMultipleSharesTracIndependently() {
        let model = ShareScanStatusModel()
        model.scanStarted(shareID: "a", name: "Alpha")
        model.scanStarted(shareID: "b", name: "Beta")
        model.scanFinished(shareID: "a")
        XCTAssertTrue(model.isAnyBusy, "Beta still scanning")
        XCTAssertEqual(model.busyShareNames, ["Beta"])
    }

    func testReporterForwardsToModel() async {
        let model = ShareScanStatusModel()
        let reporter = model.reporter()
        reporter.scanStarted("s1", "NAS")
        // Reporter hops onto the main actor asynchronously; yield until it lands.
        for _ in 0..<20 where !model.isAnyBusy { await Task.yield() }
        XCTAssertTrue(model.isAnyBusy)
        XCTAssertEqual(model.state(forShareID: "s1")?.name, "NAS")
    }

    func testReporterDeliversFullLifecycleInOrder() async {
        // Every event routes through one serialized stream, so a whole
        // scan→enrich lifecycle applies in order and ends cleanly (no stuck banner,
        // last-scanned stamped) even though the events are fired back-to-back.
        let model = ShareScanStatusModel()
        let r = model.reporter()
        r.scanStarted("s1", "NAS")
        r.scanProgress("s1", 10)
        r.scanFinished("s1")
        r.enrichStarted("s1", 30)
        r.enrichProgress("s1", 15)
        r.enrichFinished("s1")

        var tries = 0
        while tries < 200, model.isAnyBusy || model.state(forShareID: "s1")?.lastScanAt == nil {
            await Task.yield(); tries += 1
        }
        let s = model.state(forShareID: "s1")
        XCTAssertEqual(s?.itemsFound, 10, "progress applied")
        XCTAssertNotNil(s?.lastScanAt, "finish stamped a last-scanned time")
        XCTAssertFalse(model.isAnyBusy, "enrich finish applied — indicator cleared")
    }
}
