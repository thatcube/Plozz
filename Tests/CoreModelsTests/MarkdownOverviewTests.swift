import XCTest
@testable import CoreModels

/// Flattening link markup for surfaces where links can't be tapped (tvOS).
final class MarkdownOverviewTests: XCTestCase {
    func testFlattensAniDBRawLinksToTheirLabel() {
        // The form Jellyfin/Plex deliver from AniDB metadata agents: a bare URL
        // followed by the display name in brackets.
        let raw = "http://anidb.net/character/153740 [Tanba Tetsuo] and "
            + "http://anidb.net/character/153741 [Kurogane Misaki] are two operatives."
        XCTAssertEqual(
            raw.overviewPlainText,
            "Tanba Tetsuo and Kurogane Misaki are two operatives."
        )
    }

    func testFlattensMarkdownLinksToTheirLabel() {
        XCTAssertEqual(
            "[Taiju](http://anidb.net/ch99858) wakes up.".overviewPlainText,
            "Taiju wakes up."
        )
    }

    func testHandlesBothFormsInOneOverview() {
        let raw = "http://anidb.net/character/1 [Sei] meets [Taiju](http://anidb.net/ch2)."
        XCTAssertEqual(raw.overviewPlainText, "Sei meets Taiju.")
    }

    func testLeavesABareURLAlone() {
        // No bracketed label follows, so this is likely a genuine credit rather than
        // link markup — removing it would delete information.
        let raw = "A story about hope. Source: http://anidb.net/anime/1234"
        XCTAssertEqual(raw.overviewPlainText, raw)
    }

    func testLeavesOrdinaryBracketsAlone() {
        let raw = "The [second] season adapts the manga."
        XCTAssertEqual(raw.overviewPlainText, raw)
    }

    func testLeavesPlainProseUntouched() {
        let raw = "Juliette finds sanctuary in a silo long ago destroyed by war."
        XCTAssertEqual(raw.overviewPlainText, raw)
    }

    func testCollapsesTheGapLeftBehindByARemovedURL() {
        let raw = "Meet http://anidb.net/character/1 [Sei]  today."
        XCTAssertFalse(raw.overviewPlainText.contains("  "))
    }

    func testKeepsTheRawStringAvailableForPlatformsThatRenderLinks() {
        // iOS/iPadOS render real links from the markdown form, so flattening must
        // never be applied at the model boundary — the raw value stays intact.
        let raw = "[Taiju](http://anidb.net/ch99858) wakes up."
        XCTAssertNotNil(raw.overviewMarkdown)
        XCTAssertEqual(raw, "[Taiju](http://anidb.net/ch99858) wakes up.")
    }
}
