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
    // MARK: Several links in a row

    func testConsecutiveMarkdownLinksEachKeepTheirOwnLabel() {
        // Kokoro Connect names four characters back to back. Letting the AniDB
        // pattern's URL run past its own closing paren made each link swallow the
        // next one's label, so the hero read
        // "[Taichi](Iori(Himeko(Yoshifumi(http://anidb.net/ch41931)".
        let raw = "The story involves five high school students, "
            + "[Taichi](http://anidb.net/ch41928), [Iori](http://anidb.net/ch41929), "
            + "[Himeko](http://anidb.net/ch41930), [Yoshifumi](http://anidb.net/ch41931) and Yui."
        let flattened = raw.overviewPlainText
        XCTAssertEqual(
            flattened,
            "The story involves five high school students, Taichi, Iori, Himeko, Yoshifumi and Yui."
        )
        XCTAssertFalse(flattened.contains("anidb.net"))
        XCTAssertFalse(flattened.contains("["))
        XCTAssertFalse(flattened.contains("("))
    }

    func testConsecutiveAniDBLinksEachKeepTheirOwnLabel() {
        let raw = "Five students, http://anidb.net/ch41928 [Taichi], "
            + "http://anidb.net/ch41929 [Iori] and Yui."
        XCTAssertEqual(raw.overviewPlainText, "Five students, Taichi, Iori and Yui.")
    }

    func testTheTwoSyntaxesSurviveEachOthersCompany() {
        // A synopsis edited by more than one agent can carry both forms at once.
        let raw = "See [Taichi](http://anidb.net/ch41928) and http://anidb.net/ch41929 [Iori]."
        XCTAssertEqual(raw.overviewPlainText, "See Taichi and Iori.")
    }

    func testAURLContainingParenthesesIsStillLeftAlone() {
        // A bare URL is a plausible "Source:" credit, so it is never rewritten —
        // and excluding parens from the pattern must not change that.
        let raw = "Source: https://en.wikipedia.org/wiki/Fargo_(1996_film)"
        XCTAssertEqual(raw.overviewPlainText, raw)
    }

}
