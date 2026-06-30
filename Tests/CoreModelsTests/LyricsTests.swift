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
        XCTAssertEqual(lyrics.lines[0].start ?? -1, 0, accuracy: 0.001)
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

    func testLRCWithLeadingBOMParsesFirstLine() throws {
        // A BOM-prefixed `.lrc` (some Plex sidecars) must not turn the first
        // timestamped line into an untimed plain line.
        let lyrics = try XCTUnwrap(Lyrics(lrc: "\u{FEFF}[00:01.00]First\n[00:02.00]Second"))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "Second"])
        XCTAssertEqual(lyrics.lines[0].start ?? -1, 1, accuracy: 0.001)
    }

    func testLRCNormalizesLoneCarriageReturns() throws {
        // Classic-Mac line breaks (lone \r) split lines, not stay inside text.
        let lyrics = try XCTUnwrap(Lyrics(lrc: "[00:01.00]A\r[00:02.00]B"))
        XCTAssertEqual(lyrics.lines.map(\.text), ["A", "B"])
    }

    func testPlainTextNormalizesLoneCarriageReturns() {
        let lyrics = Lyrics(plainText: "A\rB\rC")
        XCTAssertEqual(lyrics.lines.map(\.text), ["A", "B", "C"])
    }

    // MARK: Plex payload routing (plexLyricsText)

    /// Regression: an `.lrc` sidecar starting with a metadata tag (`[ar:…]`) must
    /// be parsed as LRC, not misrouted to the JSON parser by its leading `[`.
    func testPlexLyricsTextParsesLRCSidecarWithMetadataTag() throws {
        let lrc = "[ar:Some Artist]\n[00:01.00]First\n[00:02.00]Second"
        let lyrics = try XCTUnwrap(Lyrics(plexLyricsText: lrc))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "Second"])
    }

    /// An `.lrc` sidecar whose very first character is a timestamp `[` — the
    /// common case that the old `{`/`[` sniff sent to the failing JSON parser.
    func testPlexLyricsTextParsesLRCSidecarStartingWithTimestamp() throws {
        let lrc = "[00:01.00]First\n[00:02.00]Second"
        let lyrics = try XCTUnwrap(Lyrics(plexLyricsText: lrc))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "Second"])
    }

    /// Plex's own timed-JSON payload still parses (synced) through the same entry.
    func testPlexLyricsTextParsesTimedJSON() throws {
        let json = """
        [{"startOffset":1000,"endOffset":2000,"Span":[{"text":"Hello"}]},
         {"startOffset":2000,"endOffset":3000,"Span":[{"text":"World"}]}]
        """
        let lyrics = try XCTUnwrap(Lyrics(plexLyricsText: json))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Hello", "World"])
    }

    /// A non-JSON, non-LRC body falls back to plain text (unsynced).
    func testPlexLyricsTextParsesPlainText() throws {
        let lyrics = try XCTUnwrap(Lyrics(plexLyricsText: "Just a line\nAnd another"))
        XCTAssertFalse(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Just a line", "And another"])
    }

    /// Malformed JSON-shaped input (`{…}`) is never rendered raw as plain text:
    /// when no parser succeeds the initializer returns nil.
    func testPlexLyricsTextRejectsMalformedJSON() {
        XCTAssertNil(Lyrics(plexLyricsText: "{ not valid json"))
    }

    /// Empty / whitespace-only input yields nil rather than an empty Lyrics.
    func testPlexLyricsTextRejectsEmptyInput() {
        XCTAssertNil(Lyrics(plexLyricsText: "   \n  "))
    }
}
