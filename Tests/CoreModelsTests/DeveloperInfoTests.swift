import XCTest
@testable import CoreModels

final class DeveloperInfoTests: XCTestCase {
    func testCopyTextJoinsLabelValuePairs() {
        let items = [
            DeveloperInfoItem(id: "a", label: "App", value: "Plozz"),
            DeveloperInfoItem(id: "b", label: "Build #", value: "2348"),
        ]
        XCTAssertEqual(DeveloperInfo.copyText(items), "App: Plozz\nBuild #: 2348")
    }

    func testCopyTextAppendsExtraItems() {
        let items = [DeveloperInfoItem(id: "a", label: "App", value: "Plozz")]
        let extra = [DeveloperInfoItem(id: "os", label: "OS", value: "tvOS 27")]
        XCTAssertEqual(DeveloperInfo.copyText(items, extra: extra), "App: Plozz\nOS: tvOS 27")
    }

    func testSnapshotSurfacesChannelAndAlwaysHasCoreRows() {
        let items = DeveloperInfo.snapshot(channel: .testflight)
        let ids = Set(items.map(\.id))
        for expected in ["app", "build-kind", "bundle-id", "version", "build-number", "channel", "app-group", "crash-endpoint"] {
            XCTAssertTrue(ids.contains(expected), "missing \(expected)")
        }
        XCTAssertEqual(items.first(where: { $0.id == "channel" })?.value, "TestFlight")
    }
}
