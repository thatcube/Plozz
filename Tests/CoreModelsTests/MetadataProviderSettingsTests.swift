import XCTest
@testable import CoreModels

/// Locks the ``MetadataProviderSettings`` persistence + override-shape contract for the
/// single-ordered-list (enabled + order, "Disabled" divider) provider surface, including
/// one-way migration from the legacy Step-6 role blob.
final class MetadataProviderSettingsTests: XCTestCase {
    func testDefaultIsEmpty() {
        XCTAssertTrue(MetadataProviderSettings.default.isEmpty)
        XCTAssertEqual(MetadataProviderSettings.default.orderMode, .recommended)
        XCTAssertFalse(MetadataProviderSettings.default.preferOnlineArtwork)
        XCTAssertTrue(MetadataProviderSettings().enabledOrder.isEmpty)
        XCTAssertTrue(MetadataProviderSettings().disabledOrder.isEmpty)
    }

    func testSetLists() {
        var settings = MetadataProviderSettings()
        settings.setLists(enabled: [.tmdb, .tvdb], disabled: [.omdb])
        XCTAssertEqual(settings.enabledOrder, ["tmdb", "tvdb"])
        XCTAssertEqual(settings.disabledOrder, ["omdb"])
        XCTAssertTrue(settings.isExplicitlyEnabled(.tmdb))
        XCTAssertTrue(settings.isDisabled(.omdb))
        XCTAssertFalse(settings.isEmpty)
    }

    func testRoundTrips() throws {
        var original = MetadataProviderSettings(
            orderMode: .custom,
            preferOnlineArtwork: true
        )
        original.setLists(enabled: [.anilist, .tvdb, .tmdb], disabled: [.omdb, .wikipedia])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEncodedShapeIsCurrentSchema() throws {
        var settings = MetadataProviderSettings()
        settings.setLists(enabled: [.tvdb], disabled: [.omdb])
        let json = String(data: try JSONEncoder().encode(settings), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""orderMode":"recommended""#))
        XCTAssertTrue(json.contains(#""preferOnlineArtwork":false"#))
        XCTAssertTrue(json.contains("enabledOrder"))
        XCTAssertTrue(json.contains("disabledOrder"))
        XCTAssertFalse(json.contains("roleOverrides"), "legacy schema must not be re-emitted")
    }

    // MARK: Legacy migration

    func testMigratesLegacyDisabledRoleBelowDivider() throws {
        let legacy = Data(#"{"roleOverrides":{"tmdb":"disabled"},"order":["tvdb","tmdb","anilist"]}"#.utf8)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: legacy)
        // tmdb (disabled) drops below the divider; the rest stay enabled in order.
        XCTAssertEqual(decoded.enabledOrder, ["tvdb", "anilist"])
        XCTAssertEqual(decoded.disabledOrder, ["tmdb"])
        XCTAssertEqual(decoded.orderMode, .custom)
    }

    func testMigratesPrimaryAndSecondaryToEnabledPreservingOrder() throws {
        // primary/secondary both become plain enabled at their persisted order position
        // (secondary just becomes lower in the single order — no separate demotion).
        let legacy = Data(#"{"roleOverrides":{"tvdb":"primary","tmdb":"secondary"},"order":["tvdb","tmdb","anilist"]}"#.utf8)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: legacy)
        XCTAssertEqual(decoded.enabledOrder, ["tvdb", "tmdb", "anilist"])
        XCTAssertTrue(decoded.disabledOrder.isEmpty)
        XCTAssertEqual(decoded.orderMode, .custom)
    }

    func testMigratesLegacyReorderWithoutRoles() throws {
        let legacy = Data(#"{"order":["anilist","tvdb","tmdb"],"roleOverrides":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: legacy)
        XCTAssertEqual(decoded.enabledOrder, ["anilist", "tvdb", "tmdb"])
        XCTAssertTrue(decoded.disabledOrder.isEmpty)
        XCTAssertEqual(decoded.orderMode, .custom)
    }

    func testMigrationTreatsUnknownRoleAsDisabled() throws {
        // An unrecognized/future role must NOT silently enable a source the user
        // restricted; it falls below the divider (disabled).
        let legacy = Data(#"{"roleOverrides":{"tmdb":"hidden"},"order":["tvdb","tmdb"]}"#.utf8)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: legacy)
        XCTAssertEqual(decoded.disabledOrder, ["tmdb"])
        XCTAssertEqual(decoded.enabledOrder, ["tvdb"])
        XCTAssertEqual(decoded.orderMode, .custom)
    }

    func testMigratesDisabledRoleWithoutOrderEntry() throws {
        let legacy = Data(#"{"roleOverrides":{"omdb":"disabled"}}"#.utf8)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: legacy)
        XCTAssertEqual(decoded.disabledOrder, ["omdb"])
        XCTAssertTrue(decoded.enabledOrder.isEmpty)
        XCTAssertEqual(decoded.orderMode, .custom)
    }

    func testCurrentSchemaWinsOverLegacyKeys() throws {
        // A blob carrying both schemas prefers the current one (no re-migration).
        let mixed = Data(#"{"enabledOrder":["tvdb"],"disabledOrder":[],"roleOverrides":{"tmdb":"disabled"}}"#.utf8)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: mixed)
        XCTAssertEqual(decoded.enabledOrder, ["tvdb"])
        XCTAssertTrue(decoded.disabledOrder.isEmpty)
        XCTAssertEqual(decoded.orderMode, .custom)
    }

    func testRecommendedPreservesSavedCustomLists() throws {
        let original = MetadataProviderSettings(
            orderMode: .recommended,
            enabledOrder: ["anilist", "tvdb"],
            disabledOrder: ["omdb"]
        )
        let decoded = try JSONDecoder().decode(
            MetadataProviderSettings.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.orderMode, .recommended)
        XCTAssertEqual(decoded.enabledOrder, original.enabledOrder)
        XCTAssertEqual(decoded.disabledOrder, original.disabledOrder)
        XCTAssertFalse(decoded.isEmpty, "saved custom state remains resettable while Recommended is active")
    }

    func testUnknownModePreservesDisabledProvidersAsCustom() throws {
        let data = Data(#"{"orderMode":"future","enabledOrder":[],"disabledOrder":["tmdb"]}"#.utf8)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: data)
        XCTAssertEqual(decoded.orderMode, .custom)
        XCTAssertEqual(decoded.disabledOrder, ["tmdb"])
    }

    func testMissingArtworkPreferenceMigratesOff() throws {
        let data = Data(#"{"orderMode":"recommended","enabledOrder":[],"disabledOrder":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(MetadataProviderSettings.self, from: data)
        XCTAssertFalse(decoded.preferOnlineArtwork)
    }

    func testStoreRoundTripAndScoping() {
        let defaults = UserDefaults(suiteName: "provider-settings-\(UUID().uuidString)")!
        let store = MetadataProviderSettingsStore(defaults: defaults)
        XCTAssertTrue(store.load().isEmpty)
        var settings = MetadataProviderSettings()
        settings.setDisabledOrder([.kitsu])
        store.save(settings)
        XCTAssertTrue(store.load().isDisabled(.kitsu))

        // A namespaced (non-default profile) store is isolated from the default one.
        let scoped = MetadataProviderSettingsStore(defaults: defaults, namespace: "profile-2")
        XCTAssertTrue(scoped.load().isEmpty)
    }
}
