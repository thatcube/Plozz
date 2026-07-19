import XCTest
@testable import CoreModels

/// Locks the ``MetadataProviderSettings`` persistence + override-shape contract used
/// by the Step 6 provider enable/disable + ordering surface.
final class MetadataProviderSettingsTests: XCTestCase {
    func testDefaultIsEmpty() {
        XCTAssertTrue(MetadataProviderSettings.default.isEmpty)
        XCTAssertTrue(MetadataProviderSettings().roleOverrides.isEmpty)
        XCTAssertTrue(MetadataProviderSettings().order.isEmpty)
    }

    func testSetAndClearRole() {
        var settings = MetadataProviderSettings()
        settings.setRole(.disabled, for: .tmdb)
        XCTAssertEqual(settings.role(for: .tmdb), .disabled)
        XCTAssertFalse(settings.isEmpty)
        settings.setRole(nil, for: .tmdb)
        XCTAssertNil(settings.role(for: .tmdb))
        XCTAssertTrue(settings.isEmpty)
    }

    func testSetOrderStoresRawValues() {
        var settings = MetadataProviderSettings()
        settings.setOrder([.tmdb, .tvdb])
        XCTAssertEqual(settings.order, ["tmdb", "tvdb"])
    }

    func testRoundTrips() throws {
        var original = MetadataProviderSettings()
        original.setRole(.secondary, for: .wikipedia)
        original.setRole(.disabled, for: .omdb)
        original.setOrder([.anilist, .tvdb, .tmdb])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodesLegacyBlobWithoutOrder() throws {
        let legacy = Data(#"{"roleOverrides":{"tmdb":"disabled"}}"#.utf8)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: legacy)
        XCTAssertEqual(decoded.role(for: .tmdb), .disabled)
        XCTAssertTrue(decoded.order.isEmpty)
    }

    func testStoreRoundTripAndScoping() {
        let defaults = UserDefaults(suiteName: "provider-settings-\(UUID().uuidString)")!
        let store = MetadataProviderSettingsStore(defaults: defaults)
        XCTAssertTrue(store.load().isEmpty)
        var settings = MetadataProviderSettings()
        settings.setRole(.disabled, for: .kitsu)
        store.save(settings)
        XCTAssertEqual(store.load().role(for: .kitsu), .disabled)

        // A namespaced (non-default profile) store is isolated from the default one.
        let scoped = MetadataProviderSettingsStore(defaults: defaults, namespace: "profile-2")
        XCTAssertTrue(scoped.load().isEmpty)
    }

    func testStateRawValuesMatchProviderRoleContract() {
        // The merge maps MetadataProviderState -> ProviderRole by raw value, so the
        // three raw values must stay stable and identical to ProviderRole's.
        XCTAssertEqual(MetadataProviderState.primary.rawValue, "primary")
        XCTAssertEqual(MetadataProviderState.secondary.rawValue, "secondary")
        XCTAssertEqual(MetadataProviderState.disabled.rawValue, "disabled")
    }
}
