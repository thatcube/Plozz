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

    /// A stub probe that only reports a fixed set of ports as open.
    private struct StubProbe: MediaSharePortProbing {
        let open: Set<Int>
        func isOpen(host: String, port: Int, timeout: TimeInterval) async -> Bool { open.contains(port) }
    }

    func testSweepFindsWebDAVOnUnraidPort() async {
        let sweeper = MediaSharePortSweeper(probe: StubProbe(open: [8384]), timeout: 0.1)
        let doors = await sweeper.sweep(host: "192.168.68.71", specs: [
            TransportSweepSpec(transport: .webDAV, ports: [80, 443, 8384], defaultPort: 443),
        ])
        XCTAssertEqual(doors.count, 1)
        XCTAssertEqual(doors.first?.transport, .webDAV)
        XCTAssertEqual(doors.first?.port, 8384) // non-default port is explicit
    }

    func testSweepReportsDefaultPortAsImplicitNil() async {
        let sweeper = MediaSharePortSweeper(probe: StubProbe(open: [445]), timeout: 0.1)
        let doors = await sweeper.sweep(host: "h", specs: [
            TransportSweepSpec(transport: .smb, ports: [445], defaultPort: 445),
        ])
        XCTAssertEqual(doors.first?.transport, .smb)
        XCTAssertNil(doors.first?.port)
    }

    func testSweepFindsNothingWhenClosed() async {
        let sweeper = MediaSharePortSweeper(probe: StubProbe(open: []), timeout: 0.1)
        let doors = await sweeper.sweep(host: "h", specs: [
            TransportSweepSpec(transport: .webDAV, ports: [80, 443], defaultPort: 443),
        ])
        XCTAssertTrue(doors.isEmpty)
    }
}
