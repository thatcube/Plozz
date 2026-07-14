import XCTest
import CoreModels
import ProviderShare
@testable import AppShell

@MainActor
final class UnifiedAddShareModelTests: XCTestCase {
    func testSelectingWebDAVUsesSpecificDetectedPort() {
        let model = UnifiedAddShareModel()
        let box = DiscoveredMediaShareBox(
            host: "192.168.68.71",
            displayName: "CubeBoi",
            doors: [
                .init(transport: .smb, port: nil),
                .init(transport: .webDAV, port: 80),
                .init(transport: .webDAV, port: 8384),
            ]
        )

        model.openConnect(for: box)
        model.applyTransport(.webDAV)

        XCTAssertEqual(model.portText, "8384")
        XCTAssertEqual(model.detectedPorts(for: .webDAV), [80, 8384])
    }

    func testManualEntryDefaultsToSMBWithoutAutoDetectOption() {
        let model = UnifiedAddShareModel()

        model.openManualConnect()

        XCTAssertEqual(model.selectedTransport, .smb)
        XCTAssertEqual(model.portText, "445")
    }
}
