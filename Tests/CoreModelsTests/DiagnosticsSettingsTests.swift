import XCTest
@testable import CoreModels

/// Locks the ``DiagnosticsSettings`` persistence contract: adding a field must not
/// drop a stored preference written by an older build.
final class DiagnosticsSettingsTests: XCTestCase {
    func testDecodesLegacyBlobWithoutHomePerformanceKey() throws {
        // A blob written before `homePerformanceOverlayEnabled` existed.
        let legacy = Data(#"{"isEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(DiagnosticsSettings.self, from: legacy)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertFalse(decoded.homePerformanceOverlayEnabled)
    }

    func testRoundTripsBothFields() throws {
        let original = DiagnosticsSettings(isEnabled: true, homePerformanceOverlayEnabled: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiagnosticsSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDefaultsAreOff() {
        XCTAssertFalse(DiagnosticsSettings.default.isEnabled)
        XCTAssertFalse(DiagnosticsSettings.default.homePerformanceOverlayEnabled)
    }
}
