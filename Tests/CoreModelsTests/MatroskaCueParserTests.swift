import XCTest
@testable import CoreModels

final class MatroskaCueParserTests: XCTestCase {
    func testParsesInfoTracksAndInlineCuesFromFullFile() throws {
        let fixture = MKVFixtureBuilder.make()
        let summary = try XCTUnwrap(MatroskaCueParser.parseHeader(fixture.bytes))

        // Info.
        XCTAssertEqual(summary.timestampScaleNs, fixture.timestampScaleNs)
        XCTAssertEqual(summary.durationTicks, fixture.durationTicks)
        XCTAssertEqual(summary.durationSeconds!, 7_200, accuracy: 0.001)
        XCTAssertEqual(summary.segmentDataOffset, fixture.segmentDataOffset)

        // Tracks.
        let video = try XCTUnwrap(summary.videoTrack)
        XCTAssertEqual(video.codecID, MKVFixtureBuilder.hevcCodecID)
        XCTAssertEqual(video.codecPrivate, fixture.videoCodecPrivate)
        XCTAssertEqual(video.pixelWidth, 3840)
        XCTAssertEqual(video.pixelHeight, 2160)

        let audio = try XCTUnwrap(summary.audioTrack)
        XCTAssertEqual(audio.codecID, MKVFixtureBuilder.eac3CodecID)
        XCTAssertEqual(audio.channels, 6)
        XCTAssertEqual(audio.samplingFrequency, 48_000)

        // Cues (inline at the end of the Segment but inside the buffer).
        XCTAssertEqual(summary.cues, fixture.cues)
        XCTAssertEqual(summary.cuesSegmentRelativePosition, fixture.cuesSegmentRelativePosition)
        XCTAssertEqual(summary.absoluteOffset(forSegmentRelative: fixture.cuesSegmentRelativePosition), fixture.cuesFileOffset)
    }

    func testHeaderOnlyParseFindsCuesPositionViaSeekHeadWhenCuesAreOutOfBuffer() throws {
        let fixture = MKVFixtureBuilder.make()
        // Truncate the buffer just before the trailing Cues block.
        let headerOnly = Array(fixture.bytes[0..<fixture.cuesFileOffset])
        let summary = try XCTUnwrap(MatroskaCueParser.parseHeader(headerOnly))

        XCTAssertTrue(summary.cues.isEmpty, "cues must not be parsed when they are outside the buffer")
        XCTAssertEqual(summary.cuesSegmentRelativePosition, fixture.cuesSegmentRelativePosition)
        XCTAssertEqual(summary.cuesAbsoluteOffset, fixture.cuesFileOffset)
        // Tracks/Info still parsed from the header window.
        XCTAssertEqual(summary.videoTrack?.codecID, MKVFixtureBuilder.hevcCodecID)
        XCTAssertEqual(summary.durationSeconds!, 7_200, accuracy: 0.001)
    }

    func testParseCuesMergesOutOfLineCuesUsingAbsoluteBaseOffset() throws {
        let fixture = MKVFixtureBuilder.make()
        let headerOnly = Array(fixture.bytes[0..<fixture.cuesFileOffset])
        let headerSummary = try XCTUnwrap(MatroskaCueParser.parseHeader(headerOnly))

        // Second ranged read: the Cues block sitting at the end of the file.
        let cuesWindow = Array(fixture.bytes[fixture.cuesFileOffset...])
        let merged = MatroskaCueParser.parseCues(
            cuesWindow,
            baseOffset: fixture.cuesFileOffset,
            summary: headerSummary
        )

        XCTAssertEqual(merged.cues, fixture.cues)
        // Byte offsets resolve back into the original file coordinate space.
        let firstAbsolute = merged.segmentDataOffset + merged.cues[1].clusterPosition
        XCTAssertEqual(firstAbsolute, fixture.segmentDataOffset + fixture.cues[1].clusterPosition)
    }

    func testCuesAreSortedByTime() throws {
        let fixture = MKVFixtureBuilder.make(cuePoints: [
            (12_000, 8_000_000),
            (0, 5_000),
            (6_000, 4_000_000)
        ])
        let summary = try XCTUnwrap(MatroskaCueParser.parseHeader(fixture.bytes))
        XCTAssertEqual(summary.cues.map(\.timeTicks), [0, 6_000, 12_000])
    }

    func testReturnsNilWhenNoSegmentPresent() {
        XCTAssertNil(MatroskaCueParser.parseHeader([0x1A, 0x45, 0xDF, 0xA3, 0x80]))
    }

    func testCueTimeSecondsHonorsTimestampScale() {
        let cue = MatroskaCuePoint(timeTicks: 6_000, clusterPosition: 0)
        XCTAssertEqual(cue.timeSeconds(timestampScaleNs: 1_000_000), 6.0, accuracy: 0.0001)
        XCTAssertEqual(cue.timeSeconds(timestampScaleNs: 1_000_000_000), 6_000.0, accuracy: 0.0001)
    }
}
