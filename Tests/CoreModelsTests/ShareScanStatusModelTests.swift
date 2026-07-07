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

        model.enrichStarted(shareID: "s1")
        XCTAssertTrue(model.isAnyBusy, "enrichment keeps the indicator up (art/details still resolving)")
        model.enrichFinished(shareID: "s1")
        XCTAssertFalse(model.isAnyBusy)
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
        r.enrichStarted("s1")
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
