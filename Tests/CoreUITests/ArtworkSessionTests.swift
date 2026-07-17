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

    func testArtworkSessionUsesDedicatedByteCacheAndCachePolicy() {
        let config = ArtworkSession.shared.configuration
        XCTAssertEqual(config.requestCachePolicy, .returnCacheDataElseLoad)
        XCTAssertEqual(config.httpMaximumConnectionsPerHost, 6)
        let cache = config.urlCache
        XCTAssertNotNil(cache)
        // The modernized directory-based URLCache keeps the same managed capacities.
        XCTAssertEqual(cache?.memoryCapacity, ArtworkSession.memoryCapacityBytes)
        XCTAssertEqual(cache?.diskCapacity, ArtworkSession.diskCapacityBytes)
        // It is a dedicated instance, not the tiny process-wide shared URLCache.
        XCTAssertFalse(cache === URLCache.shared)
    }
}
