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
                .init(transport: .webDAV, port: 80, scheme: "http"),
                .init(transport: .webDAV, port: 8384, scheme: "http"),
            ]
        )

        model.openConnect(for: box)
        model.applyTransport(.webDAV)

        XCTAssertEqual(model.portText, "8384")
        XCTAssertEqual(model.detectedPorts(for: .webDAV), [80, 8384])
        XCTAssertEqual(model.webDAVScheme, "http")
    }

    func testManualEntryDefaultsToSMBWithoutAutoDetectOption() {
        let model = UnifiedAddShareModel()

        model.openManualConnect()

        XCTAssertEqual(model.selectedTransport, .smb)
        XCTAssertEqual(model.portText, "445")
    }

    func testManualWebDAVWithoutSchemeProbesHTTPSThenHTTP() async {
        let model = UnifiedAddShareModel(
            serviceProbe: HTTPOnlyServiceProbe()
        )
        model.openManualConnect()
        model.applyTransport(.webDAV)
        model.address = "192.168.68.71"
        model.portText = "8384"
        model.username = "user"

        model.connect()
        for _ in 0..<20 where model.webDAVScheme == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.webDAVScheme, "http")
        XCTAssertTrue(model.connectError?.contains("uses HTTP") == true)
        XCTAssertNotNil(model.plaintextWarning)
    }

    private struct HTTPOnlyServiceProbe: MediaShareServiceProbing {
        func confirms(
            host: String,
            target: TransportSweepTarget,
            timeout: TimeInterval
        ) async -> Bool {
            target.probe == .webDAVHTTP
        }
    }
}
