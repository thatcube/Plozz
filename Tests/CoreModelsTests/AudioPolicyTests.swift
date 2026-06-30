import XCTest
@testable import CoreModels

final class AudioPolicyTests: XCTestCase {

    // MARK: AudioLanguagePreference token round-trip + Codable

    func testTokenRoundTrip() {
        XCTAssertEqual(AudioLanguagePreference.original.token, "original")
        XCTAssertEqual(AudioLanguagePreference.device.token, "device")
        XCTAssertEqual(AudioLanguagePreference.language("ja").token, "lang:ja")

        XCTAssertEqual(AudioLanguagePreference(token: "original"), .original)
        XCTAssertEqual(AudioLanguagePreference(token: "device"), .device)
        XCTAssertEqual(AudioLanguagePreference(token: "lang:en"), .language("en"))
    }

    func testTokenToleratesBareCodeAndJunk() {
        XCTAssertEqual(AudioLanguagePreference(token: "fr"), .language("fr"), "A bare code maps to .language.")
        XCTAssertEqual(AudioLanguagePreference(token: "  "), .original, "Empty/blank falls back to .original.")
        XCTAssertEqual(AudioLanguagePreference(token: "lang:"), .original, "An empty language code falls back to .original.")
    }

    func testPreferenceCodableAsSingleStringValue() throws {
        let cases: [AudioLanguagePreference] = [.original, .device, .language("ja")]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            let decoded = String(data: data, encoding: .utf8)
            XCTAssertEqual(decoded, "\"\(value.token)\"", "Encodes as the bare token string.")
            XCTAssertEqual(try JSONDecoder().decode(AudioLanguagePreference.self, from: data), value)
        }
    }

    func testExplicitLanguageCodeAccessor() {
        XCTAssertEqual(AudioLanguagePreference.language("ko").explicitLanguageCode, "ko")
        XCTAssertNil(AudioLanguagePreference.original.explicitLanguageCode)
        XCTAssertNil(AudioLanguagePreference.device.explicitLanguageCode)
    }

    // MARK: AudioPolicy resolution

    func testEffectivePreferenceUsesOverrideThenBase() {
        let policy = AudioPolicy(
            basePreference: .device,
            overrides: [.anime: .original]
        )
        XCTAssertEqual(policy.effectivePreference(for: .anime), .original, "Override wins for its category.")
        XCTAssertEqual(policy.effectivePreference(for: .movie), .device, "No override falls back to the base.")
        XCTAssertEqual(policy.effectivePreference(for: .other), .device, "`.other` always uses the base.")
    }

    func testInheritingFromSettingsMirrorsBaseAndHasNoOverrides() {
        let settings = PlaybackSettings(audioLanguagePreference: .language("en"))
        let policy = AudioPolicy.inheriting(from: settings)
        XCTAssertEqual(policy.basePreference, .language("en"))
        XCTAssertTrue(policy.overrides.isEmpty)
        XCTAssertEqual(policy.effectivePreference(for: .anime), .language("en"))
    }

    func testResolvedAppliesBaseAndOverrides() {
        let policy = AudioPolicy.resolved(base: .original, overrides: [.movie: .device])
        XCTAssertEqual(policy.basePreference, .original)
        XCTAssertEqual(policy.effectivePreference(for: .movie), .device)
        XCTAssertEqual(policy.effectivePreference(for: .anime), .original)
    }

    func testSmartDefaultOverridesSeedAnimeOriginalElseDevice() {
        let seed = AudioPolicy.smartDefaultOverrides()
        XCTAssertEqual(seed[.anime], .original)
        XCTAssertEqual(seed[.movie], .device)
        XCTAssertEqual(seed[.tvShow], .device)
        XCTAssertNil(seed[.other], "`.other` is never seeded; it follows the base.")
    }

    func testPolicyCodableRoundTrip() throws {
        let policy = AudioPolicy(basePreference: .device, overrides: [.anime: .original, .movie: .language("fr")])
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(AudioPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
    }

    // MARK: Store + model

    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "AudioPolicyTests.\(name)")!
        defaults.removePersistentDomain(forName: "AudioPolicyTests.\(name)")
        return defaults
    }

    func testStorePersistsAndClearsOverrides() {
        let store = AudioPolicyStore(defaults: makeDefaults(), namespace: nil)
        XCTAssertTrue(store.overrides().isEmpty, "Empty by default.")

        store.setPreference(.original, for: .anime)
        XCTAssertEqual(store.overrides()[.anime], .original)

        store.setPreference(nil, for: .anime)
        XCTAssertTrue(store.overrides().isEmpty, "Clearing the last override empties the store.")
    }

    func testStoreResolvedPolicyUsesSettingsBase() {
        let store = AudioPolicyStore(defaults: makeDefaults(), namespace: nil)
        store.setOverrides([.movie: .device])
        let settings = PlaybackSettings(audioLanguagePreference: .original)
        let resolved = store.resolvedPolicy(settings: settings)
        XCTAssertEqual(resolved.basePreference, .original)
        XCTAssertEqual(resolved.effectivePreference(for: .movie), .device)
        XCTAssertEqual(resolved.effectivePreference(for: .anime), .original)
    }

    @MainActor
    func testModelWritesThroughToStore() {
        let store = AudioPolicyStore(defaults: makeDefaults(), namespace: nil)
        let model = AudioPolicyModel(store: store)
        model.overrides = [.anime: .original]
        XCTAssertEqual(store.overrides()[.anime], .original, "Model edits persist to the store.")

        let reloaded = AudioPolicyModel(store: store)
        XCTAssertEqual(reloaded.overrides[.anime], .original, "A fresh model reads the persisted overrides.")
    }
}
