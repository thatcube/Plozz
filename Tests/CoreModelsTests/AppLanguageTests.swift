import XCTest
@testable import CoreModels

final class AppLanguageTests: XCTestCase {

    // MARK: Storage round-trip

    func testSystemRoundTripsThroughStorage() {
        XCTAssertEqual(AppLanguage(storageValue: AppLanguage.system.storageValue), .system)
        XCTAssertEqual(AppLanguage.system.storageValue, "")
    }

    func testExplicitRoundTripsThroughStorage() {
        let spanish = AppLanguage.explicit("es")
        XCTAssertEqual(AppLanguage(storageValue: spanish.storageValue), spanish)
    }

    /// A missing key reads as "" and must mean "follow the system", not a broken
    /// language tag — otherwise a fresh install would try to resolve `""`.
    func testUnsetStorageMeansSystem() {
        XCTAssertEqual(AppLanguage(storageValue: ""), .system)
    }

    // MARK: Locale construction

    /// `.system` must inject nothing. Substituting `Locale.current` here would
    /// freeze the app's language at launch and stop it following a change the
    /// user makes in Settings.app.
    func testSystemProducesNoLocaleOverride() {
        XCTAssertNil(AppLanguage.system.locale)
    }

    func testExplicitLanguageProducesMatchingLocale() {
        let locale = AppLanguage.explicit("es").locale
        XCTAssertEqual(locale?.language.languageCode?.identifier, "es")
    }

    /// Choosing a language must not also move dates, numbers and currency to that
    /// language's home country — someone in the US reading Plozz in Spanish still
    /// wants US formats.
    func testExplicitLanguageKeepsDeviceRegion() throws {
        let region = try XCTUnwrap(Locale.current.region)
        let locale = try XCTUnwrap(AppLanguage.explicit("es").locale)
        XCTAssertEqual(locale.region, region)
    }

    // MARK: Available languages

    /// The picker is built from what the bundle SHIPS, so a language can never be
    /// offered with no strings behind it.
    func testAvailableAlwaysOffersSystemFirst() {
        XCTAssertEqual(AppLanguage.available().first, .system)
    }

    func testAvailableOnlyIncludesShippedLocalizations() {
        let bundle = Bundle(for: type(of: self))
        let shipped = Set(bundle.localizations.filter { $0 != "Base" })

        for language in AppLanguage.available(in: bundle) {
            guard case let .explicit(code) = language else { continue }
            XCTAssertTrue(shipped.contains(code), "\(code) is offered but not shipped")
        }
    }

    /// DEBUG lifts the release gate so an in-progress translation can be reviewed
    /// without changing the whole device's language. The release path must still
    /// be driven by `releaseReady` alone — a bundled .lproj means only that SOME
    /// strings were translated, and offering a 6%-complete language shows a
    /// mostly-English UI to someone who explicitly asked for it.
    func testDebugOffersShippedLocalizationsBeyondReleaseReady() throws {
        #if !DEBUG
        throw XCTSkip("Release builds offer only releaseReady languages.")
        #else
        let bundle = Bundle(for: type(of: self))
        let shipped = Set(bundle.localizations).subtracting(["Base", "en"])
        try XCTSkipIf(shipped.isEmpty, "No non-English localization bundled to check against.")

        let offered = Set(AppLanguage.available(in: bundle).compactMap { language -> String? in
            guard case let .explicit(code) = language else { return nil }
            return code
        })
        XCTAssertEqual(offered, shipped)
        // The point of the DEBUG branch: these are languages releaseReady omits.
        XCTAssertFalse(shipped.isSubset(of: Set(AppLanguage.releaseReady)))
        for code in shipped { XCTAssertTrue(AppLanguage.isInProgress(code)) }
        #endif
    }

    func testAvailableExcludesBaseLocalization() {
        let offered = AppLanguage.available().map(\.storageValue)
        XCTAssertFalse(offered.contains("Base"))
    }

    // MARK: Display names

    /// Languages are listed by endonym — the name written in that language — which
    /// is what someone scanning for their own language actually recognises.
    func testExplicitLanguageUsesItsOwnEndonym() {
        XCTAssertEqual(AppLanguage.explicit("es").endonym, "Español")
        XCTAssertEqual(AppLanguage.explicit("de").endonym, "Deutsch")
    }

    /// `.system` has no endonym — its label is app copy, kept as a resource so it
    /// re-resolves with the injected locale instead of being frozen at launch.
    func testSystemHasNoEndonymAndUsesACopyResource() {
        XCTAssertNil(AppLanguage.system.endonym)
        XCTAssertFalse(String(localized: AppLanguage.systemOptionTitle).isEmpty)
    }

    /// A regional tag must keep its region on the LANGUAGE — that is what selects
    /// the `.lproj` — while the FORMATTING region still follows the device.
    ///
    /// These are two different things and easy to conflate: `Locale.region` is the
    /// formatting override (`@rg=`), whereas `Locale.language.region` is what
    /// resolves resources. "pt-BR" for a user in the US must give Brazilian
    /// Portuguese text with US dates.
    func testRegionalTagKeepsLanguageRegionButUsesDeviceFormatting() throws {
        let locale = try XCTUnwrap(AppLanguage.explicit("pt-BR").locale)
        XCTAssertEqual(locale.language.languageCode?.identifier, "pt")
        XCTAssertEqual(locale.language.region?.identifier, "BR",
                       "The language region selects the localization and must survive")
        XCTAssertEqual(locale.region, Locale.current.region,
                       "Formatting still follows the device")
    }

    /// Only languages declared release-ready may be offered, however many
    /// `.lproj` folders happen to be in the bundle — a 10%-translated language
    /// must not be selectable.
    func testOnlyReleaseReadyLanguagesAreOffered() {
        let offered = Set(AppLanguage.available().compactMap { language -> String? in
            guard case let .explicit(code) = language else { return nil }
            return code
        })
        XCTAssertTrue(offered.isSubset(of: Set(AppLanguage.releaseReady)))
    }

    // MARK: Persistence

    func testStorePersistsAndReloadsSelection() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }

        let store = AppLanguageSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), .system, "Defaults to following the device")

        store.save(.explicit("de"))
        XCTAssertEqual(AppLanguageSettingsStore(defaults: defaults).load(), .explicit("de"))
    }

    /// Each profile keeps its own language, so one household member can read
    /// Plozz in Spanish while another keeps English on the same Apple TV.
    func testLanguageIsScopedPerProfile() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }

        let primary = AppLanguageSettingsStore(defaults: defaults)
        let guest = AppLanguageSettingsStore(defaults: defaults, namespace: "guest-profile")

        primary.save(.explicit("es"))
        guest.save(.explicit("de"))

        XCTAssertEqual(primary.load(), .explicit("es"))
        XCTAssertEqual(guest.load(), .explicit("de"))
    }
}
