import XCTest
@testable import CoreUI

final class ArtworkSessionTests: XCTestCase {
    func testArtworkByteCacheUsesManagedCapacity() {
        let usage = ArtworkSession.cacheUsage()
        XCTAssertEqual(ArtworkSession.memoryCapacityBytes, 64 * 1024 * 1024)
        XCTAssertEqual(ArtworkSession.diskCapacityBytes, 384 * 1024 * 1024)
        XCTAssertEqual(usage.memoryCapacityBytes, ArtworkSession.memoryCapacityBytes)
        XCTAssertEqual(usage.diskCapacityBytes, ArtworkSession.diskCapacityBytes)
        XCTAssertGreaterThanOrEqual(usage.memoryBytes, 0)
        XCTAssertGreaterThanOrEqual(usage.diskBytes, 0)
    }
}
