import XCTest
import CoreGraphics
@testable import CoreModels

final class SubtitleCueParserTests: XCTestCase {

    // MARK: - SubRip

    func testBasicSRT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello world

        2
        00:00:05,500 --> 00:00:07,250
        Second line
        """
        let stream = SubtitleCueParser.parse(srt, id: 7)
        XCTAssertEqual(stream.metadata.format, .srt)
        XCTAssertEqual(stream.metadata.sourceTrackID, 7)
        XCTAssertEqual(stream.cues.count, 2)

        XCTAssertEqual(stream.cues[0].start, 1.0, accuracy: 0.0001)
        XCTAssertEqual(stream.cues[0].end, 4.0, accuracy: 0.0001)
        XCTAssertEqual(stream.cues[0].text, "Hello world")
        XCTAssertEqual(stream.cues[0].id, 0)

        XCTAssertEqual(stream.cues[1].start, 5.5, accuracy: 0.0001)
        XCTAssertEqual(stream.cues[1].end, 7.25, accuracy: 0.0001)
        XCTAssertEqual(stream.cues[1].text, "Second line")
        XCTAssertEqual(stream.cues[1].id, 1)
    }

    func testSRTMultiLineText() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        Line one
        Line two
        """
        let cues = SubtitleCueParser.parseCues(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Line one\nLine two")
    }

    func testSRTNumericCounterIsNotTreatedAsText() {
        let srt = """
        42
        00:00:01,000 --> 00:00:02,000
        Body
        """
        let cues = SubtitleCueParser.parseCues(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Body", "the SRT counter line must not leak into the text")
    }

    // MARK: - WebVTT

    func testBasicWebVTT() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        Hello from VTT
        """
        let stream = SubtitleCueParser.parse(vtt)
        XCTAssertEqual(stream.metadata.format, .webVTT)
        XCTAssertEqual(stream.cues.count, 1)
        XCTAssertEqual(stream.cues[0].text, "Hello from VTT")
        XCTAssertEqual(stream.cues[0].start, 1.0, accuracy: 0.0001)
    }

    func testWebVTTWithCueIdentifierAndHeaderMetadata() {
        let vtt = """
        WEBVTT
        Kind: captions
        Language: en

        intro
        00:00:00.000 --> 00:00:02.000
        First
        """
        let cues = SubtitleCueParser.parseCues(vtt)
        XCTAssertEqual(cues.count, 1, "the WEBVTT header block must be ignored, the cue identifier line dropped")
        XCTAssertEqual(cues[0].text, "First")
    }

    func testWebVTTTimestampWithoutHours() {
        let vtt = """
        WEBVTT

        01:02.500 --> 01:05.000
        No hours field
        """
        let cues = SubtitleCueParser.parseCues(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 62.5, accuracy: 0.0001)
        XCTAssertEqual(cues[0].end, 65.0, accuracy: 0.0001)
    }

    func testNoteAndStyleBlocksSkipped() {
        let vtt = """
        WEBVTT

        NOTE this is a comment

        STYLE
        ::cue { color: yellow }

        00:00:01.000 --> 00:00:02.000
        Only cue
        """
        let cues = SubtitleCueParser.parseCues(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Only cue")
    }

    // MARK: - Inline markup

    func testItalicAndBoldTagsBecomeFlagsAndAreStripped() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        <i>Whispered</i> and <b>shouted</b>
        """
        let cues = SubtitleCueParser.parseCues(srt)
        XCTAssertEqual(cues.count, 1)
        guard case .text(let t) = cues[0].body else { return XCTFail("expected text body") }
        XCTAssertEqual(t.string, "Whispered and shouted")
        XCTAssertTrue(t.isItalic)
        XCTAssertTrue(t.isBold)
    }

    func testUnknownTagsAreStripped() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        <v Roger>Hi</v> <c.loud>there</c> <00:00:01.500>now
        """
        let cues = SubtitleCueParser.parseCues(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hi there now")
    }

    func testHTMLEntitiesDecoded() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        Tom &amp; Jerry &lt;3 &quot;quoted&quot;
        """
        let cues = SubtitleCueParser.parseCues(srt)
        XCTAssertEqual(cues[0].text, "Tom & Jerry <3 \"quoted\"")
    }

    // MARK: - Cue settings → layout

    func testPlainCueHasNoLayout() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        Plain dialogue
        """
        let cues = SubtitleCueParser.parseCues(vtt)
        guard case .text(let t) = cues[0].body else { return XCTFail("expected text body") }
        XCTAssertNil(t.layout, "a cue with no settings stays in the user's default dialogue lane")
    }

    func testCueSettingsProduceSourcePositionedLayout() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000 position:50% line:10% align:center
        Top sign
        """
        let cues = SubtitleCueParser.parseCues(vtt)
        guard case .text(let t) = cues[0].body else { return XCTFail("expected text body") }
        let layout = try? XCTUnwrap(t.layout)
        XCTAssertEqual(layout?.alignment, .topCenter, "line:10% lands in the top band")
        XCTAssertTrue(layout?.isSourcePositioned == true)
        XCTAssertEqual(layout?.anchor?.x ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(layout?.anchor?.y ?? -1, 0.1, accuracy: 0.0001)
    }

    func testAlignOnlySettingStaysInDefaultLane() {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000 align:start
        Justified but not positioned
        """
        let cues = SubtitleCueParser.parseCues(vtt)
        guard case .text(let t) = cues[0].body else { return XCTFail("expected text body") }
        XCTAssertNil(t.layout, "justification alone must not pin the cue out of the dialogue lane")
    }

    // MARK: - Robustness

    func testZeroAndNegativeDurationCuesSkipped() {
        let srt = """
        1
        00:00:02,000 --> 00:00:02,000
        zero length

        2
        00:00:05,000 --> 00:00:04,000
        reversed

        3
        00:00:06,000 --> 00:00:08,000
        good
        """
        let cues = SubtitleCueParser.parseCues(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "good")
    }

    func testEmptyTextCueSkipped() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000


        2
        00:00:03,000 --> 00:00:04,000
        real
        """
        let cues = SubtitleCueParser.parseCues(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "real")
    }

    func testCuesAreSortedByStartWithMonotonicIDs() {
        let srt = """
        1
        00:00:10,000 --> 00:00:12,000
        later

        2
        00:00:01,000 --> 00:00:02,000
        earlier
        """
        let cues = SubtitleCueParser.parseCues(srt)
        XCTAssertEqual(cues.map(\.text), ["earlier", "later"])
        XCTAssertEqual(cues.map(\.id), [0, 1])
    }

    func testEmptyAndGarbageInput() {
        XCTAssertTrue(SubtitleCueParser.parse("").cues.isEmpty)
        XCTAssertTrue(SubtitleCueParser.parse("not a subtitle file at all").cues.isEmpty)
        XCTAssertTrue(SubtitleCueParser.parse("WEBVTT\n\n").cues.isEmpty)
    }

    func testCRLFLineEndingsHandled() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nWindows line endings\r\n"
        let cues = SubtitleCueParser.parseCues(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Windows line endings")
    }

    func testBOMStripped() {
        let srt = "\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nWith BOM"
        let stream = SubtitleCueParser.parse(srt)
        XCTAssertEqual(stream.metadata.format, .srt)
        XCTAssertEqual(stream.cues.count, 1)
        XCTAssertEqual(stream.cues[0].text, "With BOM")
    }

    func testThreeDigitAndShortMillisecondsParsed() {
        let vtt = """
        WEBVTT

        00:00:01.5 --> 00:00:02.05
        short fractions
        """
        let cues = SubtitleCueParser.parseCues(vtt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.5, accuracy: 0.0001)
        XCTAssertEqual(cues[0].end, 2.05, accuracy: 0.0001)
    }
}
