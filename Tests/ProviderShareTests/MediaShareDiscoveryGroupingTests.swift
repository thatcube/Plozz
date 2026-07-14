import XCTest
@testable import ProviderShare
import CoreModels

/// Coverage for discovery grouping (flat services → per-device boxes) and the
/// curated Channel-B port sweep (offline, with an injected probe).
final class MediaShareDiscoveryGroupingTests: XCTestCase {

    // MARK: - Grouping

    func testServicesOnOneHostCollapseToOneBox() {
        let services = [
            DiscoveredNetworkService(transport: .smb, name: "MyNAS", host: "192.168.68.71", port: nil),
            DiscoveredNetworkService(transport: .webDAV, name: "MyNAS", host: "192.168.68.71", port: 8384),
        ]
        let boxes = MediaShareBoxGrouping.group(services)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes.first?.host, "192.168.68.71")
        XCTAssertEqual(Set(boxes.first?.doors.map(\.transport) ?? []), [.smb, .webDAV])
    }

    func testDistinctHostsAreSeparateBoxes() {
        let services = [
            DiscoveredNetworkService(transport: .smb, name: "A", host: "10.0.0.1", port: nil),
            DiscoveredNetworkService(transport: .smb, name: "B", host: "10.0.0.2", port: nil),
        ]
        XCTAssertEqual(MediaShareBoxGrouping.group(services).count, 2)
    }

    func testGroupingKeepsWebDAVPortOnTheDoor() {
        let services = [
            DiscoveredNetworkService(transport: .webDAV, name: "Box", host: "h", port: 8384),
        ]
        let door = MediaShareBoxGrouping.group(services).first?.doors.first
        XCTAssertEqual(door?.transport, .webDAV)
        XCTAssertEqual(door?.port, 8384)
    }

    // MARK: - Sweep (Channel B)

    /// A stub protocol probe that confirms a fixed set of target ports.
    private struct StubProbe: MediaShareServiceProbing {
        let confirmed: Set<Int>
        func confirms(
            host: String,
            target: TransportSweepTarget,
            timeout: TimeInterval
        ) async -> Bool {
            confirmed.contains(target.port)
        }
    }

    func testSweepFindsWebDAVOnUnraidPort() async {
        let sweeper = MediaSharePortSweeper(
            probe: StubProbe(confirmed: [8384]),
            timeout: 0.1
        )
        let doors = await sweeper.sweep(host: "192.168.68.71", specs: [
            TransportSweepSpec(
                transport: .webDAV,
                targets: [
                    TransportSweepTarget(port: 80, probe: .webDAVHTTP),
                    TransportSweepTarget(port: 443, probe: .webDAVHTTPS),
                    TransportSweepTarget(port: 8384, probe: .webDAVHTTP),
                ],
                defaultPort: 443
            ),
        ])
        XCTAssertEqual(doors.count, 1)
        XCTAssertEqual(doors.first?.transport, .webDAV)
        XCTAssertEqual(doors.first?.port, 8384) // non-default port is explicit
    }

    func testSweepReportsDefaultPortAsImplicitNil() async {
        let sweeper = MediaSharePortSweeper(
            probe: StubProbe(confirmed: [443]),
            timeout: 0.1
        )
        let doors = await sweeper.sweep(host: "h", specs: [
            TransportSweepSpec(
                transport: .webDAV,
                targets: [
                    TransportSweepTarget(port: 443, probe: .webDAVHTTPS),
                ],
                defaultPort: 443
            ),
        ])
        XCTAssertEqual(doors.first?.transport, .webDAV)
        XCTAssertNil(doors.first?.port)
    }

    func testSweepFindsNothingWhenProtocolIsNotConfirmed() async {
        let sweeper = MediaSharePortSweeper(
            probe: StubProbe(confirmed: []),
            timeout: 0.1
        )
        let doors = await sweeper.sweep(host: "h", specs: [
            TransportSweepSpec(
                transport: .webDAV,
                targets: [
                    TransportSweepTarget(port: 80, probe: .webDAVHTTP),
                    TransportSweepTarget(port: 443, probe: .webDAVHTTPS),
                ],
                defaultPort: 443
            ),
        ])
        XCTAssertTrue(doors.isEmpty)
    }

    // MARK: - WebDAV evidence

    func testWebDAVResponseEvidenceAcceptsDAVHeader() {
        XCTAssertTrue(WebDAVResponseEvidence.confirms(
            statusCode: 200,
            headers: ["DAV": "1, 2"]
        ))
    }

    func testWebDAVResponseEvidenceAcceptsPROPFIND() {
        XCTAssertTrue(WebDAVResponseEvidence.confirms(
            statusCode: 200,
            headers: ["Allow": "OPTIONS, GET, PROPFIND"]
        ))
    }

    func testWebDAVResponseEvidenceAcceptsUnraidAuthRealm() {
        XCTAssertTrue(WebDAVResponseEvidence.confirms(
            statusCode: 401,
            headers: ["WWW-Authenticate": "Basic realm=\"WebDAV-Login\""]
        ))
    }

    func testWebDAVResponseEvidenceRejectsNASAdminRedirect() {
        XCTAssertFalse(WebDAVResponseEvidence.confirms(
            statusCode: 302,
            headers: [
                "Server": "nginx",
                "Location": "http://192.168.68.71/Main",
            ]
        ))
    }
}
