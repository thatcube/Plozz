import XCTest
@testable import CoreModels

final class AudioLanguagePolicyTests: XCTestCase {

    // MARK: Remembered wins over everything

    func testRememberedLanguageTakesPrecedence() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: "en",
            preference: .original,
            originalLanguage: "ja",
            deviceLanguage: "de"
        )
        XCTAssertEqual(result, ["en"], "A remembered per-series language overrides the policy preference and device.")
    }

    func testRememberedWhitespaceIsIgnored() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: "   ",
            preference: .device,
            originalLanguage: nil,
            deviceLanguage: "fr"
        )
        XCTAssertEqual(result, ["fr"], "A blank remembered value is treated as no memory and falls through.")
    }

    // MARK: Original preference

    func testOriginalWithKnownOriginalLanguage() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preference: .original,
            originalLanguage: "ja",
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, ["ja"], "Anime (original ja) with .original requests Japanese, not the device language.")
    }

    func testOriginalWithUnknownOriginalDefersToContainer() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preference: .original,
            originalLanguage: nil,
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, [], "Unknown original language expresses no preference so the container default (≈ original) wins.")
    }

    func testOriginalIgnoresBlankOriginal() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preference: .original,
            originalLanguage: "  ",
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, [], "A blank original language is treated as unknown.")
    }

    // MARK: Device preference

    func testDeviceLanguageUsedForDevicePreference() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preference: .device,
            originalLanguage: "ja",
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, ["en"], "With .device the device language drives dub selection.")
    }

    func testEmptyWhenDevicePreferenceAndNoDeviceLanguage() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preference: .device,
            originalLanguage: "ja",
            deviceLanguage: nil
        )
        XCTAssertEqual(result, [], "No device language → no preference (container default).")
    }

    func testEmptyWhenDeviceLanguageBlank() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preference: .device,
            originalLanguage: nil,
            deviceLanguage: ""
        )
        XCTAssertEqual(result, [], "A blank device language yields no preference.")
    }

    // MARK: Explicit language preference

    func testExplicitLanguageWins() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preference: .language("es"),
            originalLanguage: "ja",
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, ["es"], "An explicit language preference requests that language regardless of original/device.")
    }

    func testExplicitBlankLanguageExpressesNoPreference() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preference: .language("  "),
            originalLanguage: "ja",
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, [], "A blank explicit language is treated as no preference.")
    }

    // MARK: Untagged-track fallback

    func testTaggedLanguageMatchDoesNotForceProviderDefault() {
        let tracks = [
            MediaTrack(
                id: 1,
                kind: .audio,
                displayTitle: "Portuguese",
                language: "pt-BR",
                isDefault: true
            ),
            MediaTrack(
                id: 2,
                kind: .audio,
                displayTitle: "English",
                language: "en"
            )
        ]
        XCTAssertNil(
            AudioLanguagePolicy.fallbackTrackID(
                preferredLanguages: ["en"],
                tracks: tracks
            ),
            "Aether should resolve the tagged English track by language"
        )
    }

    func testUntaggedTracksFallBackToProviderDefault() {
        let tracks = [
            MediaTrack(
                id: 1,
                kind: .audio,
                displayTitle: "DTS 7.1",
                language: nil,
                isDefault: true
            ),
            MediaTrack(
                id: 6,
                kind: .audio,
                displayTitle: "DTS 5.1",
                language: nil
            )
        ]
        XCTAssertEqual(
            AudioLanguagePolicy.fallbackTrackID(
                preferredLanguages: ["en"],
                tracks: tracks
            ),
            1,
            "An untagged file should honor the provider-declared default, not FFmpeg's best-stream pick"
        )
    }

    func testNoResolvedLanguageDoesNotForceATrack() {
        let tracks = [
            MediaTrack(
                id: 1,
                kind: .audio,
                displayTitle: "Track 1",
                language: nil,
                isDefault: true
            )
        ]
        XCTAssertNil(
            AudioLanguagePolicy.fallbackTrackID(
                preferredLanguages: [],
                tracks: tracks
            )
        )
    }
}
