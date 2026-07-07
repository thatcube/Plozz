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
}
