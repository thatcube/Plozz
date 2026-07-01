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
}
