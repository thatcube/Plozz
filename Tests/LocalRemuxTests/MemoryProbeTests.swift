import XCTest
@testable import LocalRemux

/// Sanity coverage for the jetsam-footprint probe that backs the cold far-seek
/// memory telemetry. The exact bytes are environment-dependent, so we assert the
/// shape (non-negative, resident present, MB conversion) rather than a magnitude.
final class MemoryProbeTests: XCTestCase {

    func testSample_returnsNonNegativeFootprint() {
        let f = MemoryProbe.sample()
        XCTAssertGreaterThanOrEqual(f.physFootprint, 0)
        XCTAssertGreaterThanOrEqual(f.resident, 0)
        // A running test process always has SOME resident memory mapped.
        XCTAssertGreaterThan(f.resident, 0)
    }

    func testMBConversion() {
        let f = MemoryProbe.Footprint(physFootprint: 10_485_760, resident: 20_971_520)
        XCTAssertEqual(f.physFootprintMB, 10, accuracy: 0.001)
        XCTAssertEqual(f.residentMB, 20, accuracy: 0.001)
    }

    func testZero() {
        XCTAssertEqual(MemoryProbe.Footprint.zero, MemoryProbe.Footprint(physFootprint: 0, resident: 0))
        XCTAssertEqual(MemoryProbe.Footprint.zero.physFootprintMB, 0)
    }
}
