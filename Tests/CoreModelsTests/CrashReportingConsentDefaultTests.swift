import XCTest
@testable import CoreModels

@MainActor
final class CrashReportingConsentDefaultTests: XCTestCase {
    /// In-memory store whose persisted value we control precisely, so we can
    /// exercise the "unset" vs "explicit choice" branches without UserDefaults.
    private final class MemoryStore: CrashReportingSettingsStoring, @unchecked Sendable {
        private var stored: CrashReportingSettings?
        init(stored: CrashReportingSettings?) { self.stored = stored }
        func load() -> CrashReportingSettings { stored ?? .default }
        func loadStored() -> CrashReportingSettings? { stored }
        func save(_ settings: CrashReportingSettings) { stored = settings }
    }

    func testUnsetUsesBetaDefaultOn() {
        let model = CrashReportingSettingsModel(
            store: MemoryStore(stored: nil),
            defaultConsentWhenUnset: true
        )
        XCTAssertTrue(model.settings.isEnabled)
    }

    func testUnsetUsesProductionDefaultOff() {
        let model = CrashReportingSettingsModel(
            store: MemoryStore(stored: nil),
            defaultConsentWhenUnset: false
        )
        XCTAssertFalse(model.settings.isEnabled)
    }

    func testExplicitOptOutIsRespectedEvenInBeta() {
        let model = CrashReportingSettingsModel(
            store: MemoryStore(stored: CrashReportingSettings(isEnabled: false)),
            defaultConsentWhenUnset: true
        )
        XCTAssertFalse(model.settings.isEnabled)
    }

    func testExplicitOptInIsRespectedInProduction() {
        let model = CrashReportingSettingsModel(
            store: MemoryStore(stored: CrashReportingSettings(isEnabled: true)),
            defaultConsentWhenUnset: false
        )
        XCTAssertTrue(model.settings.isEnabled)
    }

    func testDefaultIsNotPersistedUntilUserChoosesSomething() {
        let store = MemoryStore(stored: nil)
        _ = CrashReportingSettingsModel(store: store, defaultConsentWhenUnset: true)
        // The channel default must NOT be written, so a later upgrade to a
        // production build (default off) still reverts a never-touched install.
        XCTAssertNil(store.loadStored())
    }

    func testTogglingPersistsTheChoice() {
        let store = MemoryStore(stored: nil)
        let model = CrashReportingSettingsModel(store: store, defaultConsentWhenUnset: false)
        model.settings.isEnabled = true
        XCTAssertEqual(store.loadStored(), CrashReportingSettings(isEnabled: true))
    }

    func testBetaChannelsReportBeta() {
        XCTAssertTrue(AppReleaseChannel.debug.isBeta)
        XCTAssertTrue(AppReleaseChannel.testflight.isBeta)
        XCTAssertFalse(AppReleaseChannel.production.isBeta)
    }

    func testBakedChannelIsParsedCaseInsensitively() {
        XCTAssertEqual(AppReleaseChannel.baked("testflight"), .testflight)
        XCTAssertEqual(AppReleaseChannel.baked("TestFlight"), .testflight)
        XCTAssertEqual(AppReleaseChannel.baked("  production \n"), .production)
        XCTAssertEqual(AppReleaseChannel.baked("debug"), .debug)
    }

    /// A local build leaves the setting empty, and a project generated without
    /// the bake leaves the literal `$(PLOZZ_RELEASE_CHANNEL)` behind. Neither is
    /// an answer, so both must fall through to runtime detection rather than
    /// being mistaken for a channel name.
    func testAbsentOrUnresolvedBakeYieldsNoAnswer() {
        XCTAssertNil(AppReleaseChannel.baked(nil))
        XCTAssertNil(AppReleaseChannel.baked(""))
        XCTAssertNil(AppReleaseChannel.baked("   "))
        XCTAssertNil(AppReleaseChannel.baked("$(PLOZZ_RELEASE_CHANNEL)"))
        XCTAssertNil(AppReleaseChannel.baked("nonsense"))
    }

    /// The whole point of the bake: a TestFlight build must default consent ON
    /// even when the App Store receipt runtime detection relies on is missing,
    /// which on tvOS is the normal state until a purchase happens.
    func testBakedTestFlightChannelDefaultsConsentOn() {
        XCTAssertEqual(AppReleaseChannel.baked("testflight")?.isBeta, true)
        XCTAssertEqual(AppReleaseChannel.baked("production")?.isBeta, false)
    }

    // MARK: - Developer-device marker

    /// Adding a field must never invalidate a stored choice. The synthesized
    /// decoder throws `keyNotFound` on a payload written before the field
    /// existed, and `loadStored` maps a decode failure to "never chose" — which
    /// would re-apply the beta default and silently undo an explicit opt-OUT.
    func testSettingsWrittenBeforeTheMarkerExistedStillDecode() throws {
        let legacy = Data(#"{"isEnabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(CrashReportingSettings.self, from: legacy)
        XCTAssertFalse(decoded.isEnabled, "an explicit opt-out must survive the migration")
        XCTAssertFalse(decoded.isMaintainerDevice)
    }

    func testLegacyOptInAlsoSurvives() throws {
        let legacy = Data(#"{"isEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(CrashReportingSettings.self, from: legacy)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertFalse(decoded.isMaintainerDevice)
    }

    func testMarkerRoundTrips() throws {
        let settings = CrashReportingSettings(isEnabled: true, isMaintainerDevice: true)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(CrashReportingSettings.self, from: data), settings)
    }

    func testMarkerDefaultsOffSoNobodyIsSilentlyExcluded() {
        XCTAssertFalse(CrashReportingSettings.default.isMaintainerDevice)
        XCTAssertFalse(CrashReportingSettings(isEnabled: true).isMaintainerDevice)
    }

    func testMarkerPersistsIndependentlyOfConsent() {
        let store = MemoryStore(stored: nil)
        let model = CrashReportingSettingsModel(store: store, defaultConsentWhenUnset: true)
        model.settings.isMaintainerDevice = true
        XCTAssertEqual(store.loadStored()?.isMaintainerDevice, true)
        XCTAssertEqual(store.loadStored()?.isEnabled, true)
    }
}
