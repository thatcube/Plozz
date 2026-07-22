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
}
