import XCTest
@testable import CoreModels

final class LyricsTests: XCTestCase {

    // MARK: Plain text

    func testPlainTextSplitsLinesUnsynced() {
        let lyrics = Lyrics(plainText: "First line\nSecond line\r\nThird")
        XCTAssertEqual(lyrics.lines.map(\.text), ["First line", "Second line", "Third"])
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertNil(lyrics.lines.first?.start)
        XCTAssertFalse(lyrics.isEmpty)
    }

    func testEmptyStringIsEmpty() {
        XCTAssertTrue(Lyrics(plainText: "   \n  ").isEmpty)
    }

    // MARK: LRC parsing

    func testLRCParsesTimestampsIntoSeconds() throws {
        let lrc = """
        [ar:Some Artist]
        [ti:A Song]
        [00:00.00]Intro
        [00:12.50]First line
        [01:05.00]Second line
        [01:10]No centis
        """
        let lyrics = try XCTUnwrap(Lyrics(lrc: lrc))
        XCTAssertTrue(lyrics.isSynced)
        // ID tags are skipped; four timestamped lines remain.
        XCTAssertEqual(lyrics.lines.count, 4)
        XCTAssertEqual(lyrics.lines[0].text, "Intro")
        XCTAssertEqual(lyrics.lines[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines[1].start ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines[2].start ?? -1, 65.0, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines[3].start ?? -1, 70.0, accuracy: 0.001)
    }

    func testLRCMultipleTimestampsOnOneLineExpand() throws {
        let lyrics = try XCTUnwrap(Lyrics(lrc: "[00:10.00][00:47.00]Chorus"))
        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Chorus", "Chorus"])
        XCTAssertEqual(lyrics.lines[0].start ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines[1].start ?? -1, 47, accuracy: 0.001)
    }

    func testLRCSortsByTimestamp() throws {
        let lrc = """
        [00:30.00]Later
        [00:05.00]Earlier
        """
        let lyrics = try XCTUnwrap(Lyrics(lrc: lrc))
        XCTAssertEqual(lyrics.lines.map(\.text), ["Earlier", "Later"])
    }

    func testLRCWithHoursTimestamp() throws {
        let lyrics = try XCTUnwrap(Lyrics(lrc: "[01:02:03.00]Deep cut"))
        XCTAssertEqual(lyrics.lines.first?.start ?? -1, 3723, accuracy: 0.001)
    }

    func testLRCWithoutTimestampsFallsBackToPlainText() throws {
        let lyrics = try XCTUnwrap(Lyrics(lrc: "Just\nplain\nwords"))
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Just", "plain", "words"])
    }

    func testBlankLRCReturnsNil() {
        XCTAssertNil(Lyrics(lrc: "   \n\n  "))
    }
}
