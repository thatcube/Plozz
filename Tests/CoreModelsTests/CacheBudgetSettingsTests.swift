import XCTest
@testable import CoreModels

/// Locks the ``CacheBudgetSettings`` clamping + persistence contract for the Step 6
/// user-adjustable cache budgets.
final class CacheBudgetSettingsTests: XCTestCase {
    func testDefaultsMatchBuildCaps() {
        XCTAssertEqual(CacheBudgetSettings.default.artworkCacheBytes, 64 * 1024 * 1024)
        XCTAssertEqual(CacheBudgetSettings.default.metadataCacheBytes, 16 * 1024 * 1024)
    }

    func testClampsBelowLowerBound() {
        let settings = CacheBudgetSettings(artworkCacheBytes: 0, metadataCacheBytes: 0)
        XCTAssertEqual(settings.artworkCacheBytes, CacheBudgetSettings.artworkBounds.lowerBound)
        XCTAssertEqual(settings.metadataCacheBytes, CacheBudgetSettings.metadataBounds.lowerBound)
    }

    func testClampsAboveUpperBound() {
        let settings = CacheBudgetSettings(
            artworkCacheBytes: 1 << 40,
            metadataCacheBytes: 1 << 40
        )
        XCTAssertEqual(settings.artworkCacheBytes, CacheBudgetSettings.artworkBounds.upperBound)
        XCTAssertEqual(settings.metadataCacheBytes, CacheBudgetSettings.metadataBounds.upperBound)
    }

    func testInRangeValuesPreserved() {
        let settings = CacheBudgetSettings(
            artworkCacheBytes: 100 * 1024 * 1024,
            metadataCacheBytes: 8 * 1024 * 1024
        )
        XCTAssertEqual(settings.artworkCacheBytes, 100 * 1024 * 1024)
        XCTAssertEqual(settings.metadataCacheBytes, 8 * 1024 * 1024)
    }

    func testDecodeClampsCorruptBlob() throws {
        let corrupt = Data(#"{"artworkCacheBytes":-5,"metadataCacheBytes":999999999999}"#.utf8)
        let decoded = try JSONDecoder().decode(CacheBudgetSettings.self, from: corrupt)
        XCTAssertEqual(decoded.artworkCacheBytes, CacheBudgetSettings.artworkBounds.lowerBound)
        XCTAssertEqual(decoded.metadataCacheBytes, CacheBudgetSettings.metadataBounds.upperBound)
    }

    func testStoreRoundTrip() {
        let defaults = UserDefaults(suiteName: "cache-budget-\(UUID().uuidString)")!
        let store = CacheBudgetSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), .default)
        let settings = CacheBudgetSettings(artworkCacheBytes: 32 * 1024 * 1024, metadataCacheBytes: 8 * 1024 * 1024)
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }
}
