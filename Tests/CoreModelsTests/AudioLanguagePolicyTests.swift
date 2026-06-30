import XCTest
@testable import CoreModels

final class AudioLanguagePolicyTests: XCTestCase {

    // MARK: Remembered wins over everything

    func testRememberedLanguageTakesPrecedence() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: "en",
            preferOriginal: true,
            originalLanguage: "ja",
            deviceLanguage: "de"
        )
        XCTAssertEqual(result, ["en"], "A remembered per-series language overrides prefer-original and device.")
    }

    func testRememberedWhitespaceIsIgnored() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: "   ",
            preferOriginal: false,
            originalLanguage: nil,
            deviceLanguage: "fr"
        )
        XCTAssertEqual(result, ["fr"], "A blank remembered value is treated as no memory and falls through.")
    }

    // MARK: Prefer-original

    func testPreferOriginalWithKnownOriginalLanguage() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preferOriginal: true,
            originalLanguage: "ja",
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, ["ja"], "Anime (original ja) with prefer-original on requests Japanese, not the device language.")
    }

    func testPreferOriginalWithUnknownOriginalDefersToContainer() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preferOriginal: true,
            originalLanguage: nil,
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, [], "Unknown original language expresses no preference so the container default (≈ original) wins.")
    }

    func testPreferOriginalIgnoresBlankOriginal() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preferOriginal: true,
            originalLanguage: "  ",
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, [], "A blank original language is treated as unknown.")
    }

    // MARK: Device-language fallback (prefer-original off)

    func testDeviceLanguageUsedWhenNotPreferringOriginal() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preferOriginal: false,
            originalLanguage: "ja",
            deviceLanguage: "en"
        )
        XCTAssertEqual(result, ["en"], "With prefer-original off, the device language drives dub selection.")
    }

    func testEmptyWhenNoSignalsAtAll() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preferOriginal: false,
            originalLanguage: nil,
            deviceLanguage: nil
        )
        XCTAssertEqual(result, [], "No remembered, no original, no device → no preference (container default).")
    }

    func testEmptyWhenDeviceLanguageBlank() {
        let result = AudioLanguagePolicy.preferredAudioLanguages(
            remembered: nil,
            preferOriginal: false,
            originalLanguage: nil,
            deviceLanguage: ""
        )
        XCTAssertEqual(result, [], "A blank device language yields no preference.")
    }
}
