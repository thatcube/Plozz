import XCTest
@testable import CoreModels

/// End-to-end coverage for the cue-driven static-VOD path: synthesize a real
/// Matroska byte stream (Cues stored at EOF behind a SeekHead, the common
/// real-world layout), parse it exactly the way `CueDrivenRemuxBackend` does
/// (head-window parse → follow SeekHead → parse Cues), plan the timeline, emit the
/// playlist, and assert the load-bearing Track-A guarantees:
///
///   1. EXTINF durations are derived from the Cue presentation timestamps.
///   2. The playlist is a complete VOD (EXT-X-MAP + ENDLIST), every segment
///      declared up front so a far seek can never 404.
///   3. Segment times are monotonic and the durations sum to the total duration.
///   4. The Cue cluster byte windows are contiguous and monotonic (each segment's
///      byteEnd is the next segment's byteStart) so on-demand stream-copy reads a
///      single forward range per segment.
final class CueDrivenVODIntegrationTests: XCTestCase {

    /// Reproduces the backend's two-step parse against a fixture whose Cues live
    /// past the bounded head window, forcing the SeekHead → trailing-Cues follow.
    private func parseLikeBackend(_ fixture: MKVFixture) -> MatroskaSummary {
        // Head window stops before the trailing Cues, so the first parse must
        // report the Cues position via SeekHead without having read the cues.
        let headWindow = Array(fixture.bytes[0..<fixture.cuesFileOffset])
        guard var summary = MatroskaCueParser.parseHeader(headWindow, baseOffset: 0) else {
            XCTFail("header parse failed")
            return MatroskaSummary(segmentDataOffset: 0)
        }
        XCTAssertFalse(summary.hasCues, "cues should not be in the head window")
        guard let cuesOffset = summary.cuesAbsoluteOffset else {
            XCTFail("SeekHead did not yield the Cues position")
            return summary
        }
        XCTAssertEqual(cuesOffset, fixture.cuesFileOffset, "Cues file offset from SeekHead")
        let cuesData = Array(fixture.bytes[cuesOffset...])
        summary = MatroskaCueParser.parseCues(cuesData, baseOffset: cuesOffset, summary: summary)
        XCTAssertTrue(summary.hasCues, "cues must be present after following the SeekHead")
        return summary
    }

    private func extinfDurations(in playlist: String) -> [Double] {
        playlist
            .split(separator: "\n")
            .compactMap { line -> Double? in
                guard line.hasPrefix("#EXTINF:") else { return nil }
                let value = line.dropFirst("#EXTINF:".count).dropLast() // trailing comma
                return Double(value)
            }
    }

    func testCuesDriveExtinfAndProduceCompleteVOD() {
        let fixture = MKVFixtureBuilder.make()
        let summary = parseLikeBackend(fixture)

        // 1. Cue parse correctness: recovered PTS + cluster positions match.
        XCTAssertEqual(summary.cues, fixture.cues)
        XCTAssertEqual(summary.timestampScaleNs, fixture.timestampScaleNs)
        XCTAssertEqual(summary.durationSeconds ?? 0,
                       fixture.durationTicks * Double(fixture.timestampScaleNs) / 1_000_000_000,
                       accuracy: 1e-6)

        let totalDuration = summary.durationSeconds
        // Real titles are tens of GB; the synthetic fixture's Cue cluster offsets
        // (up to 12.5 MB) model a real file far larger than the bytes we actually
        // synthesize, so declare a realistic size past the last cue for the final
        // segment's byteEnd to land on the file end (not get clamped up to a cue).
        let declaredFileSize: Int64 = 13_000_000
        let timeline = HLSSegmentPlanner.plan(
            cues: summary.cues,
            segmentDataOffset: summary.segmentDataOffset,
            timestampScaleNs: summary.timestampScaleNs,
            totalDuration: totalDuration,
            fileSize: declaredFileSize,
            targetDuration: 6
        )
        XCTAssertFalse(timeline.isEmpty)

        // 2. Complete VOD shape.
        let playlist = LocalRemuxPlaylistBuilder.makeMediaPlaylist(timeline: timeline)
        let lines = playlist.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "#EXTM3U")
        XCTAssertTrue(lines.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("#EXT-X-MAP:URI=") })
        XCTAssertEqual(lines.last, "#EXT-X-ENDLIST", "VOD must terminate with ENDLIST")

        // Every segment is declared up front (no live/sliding window).
        let extinf = extinfDurations(in: playlist)
        XCTAssertEqual(extinf.count, timeline.count)

        // 3. EXTINF values are derived from the Cue PTS deltas. The fixture's cues
        // (in seconds at 1ms scale) are 0, 6, 12, 18.5 over a 7200s title, so with
        // a 6s target each cue becomes a boundary and the EXTINF deltas are the
        // gaps between consecutive cue times, with the tail running to the end.
        let cueSeconds = summary.cues.map { $0.timeSeconds(timestampScaleNs: summary.timestampScaleNs) }
        var expectedDurations: [Double] = []
        for i in 0..<cueSeconds.count {
            let next = (i + 1 < cueSeconds.count) ? cueSeconds[i + 1] : (totalDuration ?? cueSeconds[i])
            expectedDurations.append(next - cueSeconds[i])
        }
        XCTAssertEqual(extinf.count, expectedDurations.count)
        for (got, want) in zip(extinf, expectedDurations) {
            XCTAssertEqual(got, want, accuracy: 1e-6, "EXTINF must equal the Cue-PTS-derived duration")
        }

        // 4. Monotonic start times; positive durations summing to the total.
        let starts = timeline.segments.map(\.startTime)
        XCTAssertEqual(starts, starts.sorted(), "segment start times must be monotonic")
        for seg in timeline.segments { XCTAssertGreaterThan(seg.duration, 0) }
        let sum = extinf.reduce(0, +)
        XCTAssertEqual(sum, totalDuration ?? 0, accuracy: 1e-6,
                       "EXTINF durations must sum to the title duration")

        // 5. Contiguous, monotonic Cue byte windows (one forward range per segment).
        for i in 1..<timeline.segments.count {
            XCTAssertEqual(timeline.segments[i].byteStart, timeline.segments[i - 1].byteEnd,
                           "segment byte windows must be contiguous")
            XCTAssertGreaterThan(timeline.segments[i].byteStart, timeline.segments[i - 1].byteStart,
                                 "segment byte offsets must be monotonic")
        }
        // First window starts at the first Cue's absolute cluster offset; the last
        // window runs to the end of the file (the declared total size).
        XCTAssertEqual(timeline.segments.first?.byteStart,
                       Int64(summary.segmentDataOffset + fixture.cues[0].clusterPosition))
        XCTAssertEqual(timeline.segments.last?.byteEnd, declaredFileSize)
    }

    /// A finer-grained title (cues every 4s, exact 24s duration) so the EXTINF sum
    /// equals the duration exactly and each segment is a whole number of seconds —
    /// guards the "durations sum to total" invariant on a clean boundary case.
    func testEvenCadenceDurationsSumExactlyToTotal() {
        let fixture = MKVFixtureBuilder.make(
            timestampScaleNs: 1_000_000,
            durationTicks: 24_000, // 24s at 1ms scale
            cuePoints: [
                (0, 1_000),
                (4_000, 2_000),
                (8_000, 3_000),
                (12_000, 4_000),
                (16_000, 5_000),
                (20_000, 6_000)
            ]
        )
        let summary = parseLikeBackend(fixture)
        let timeline = HLSSegmentPlanner.plan(
            cues: summary.cues,
            segmentDataOffset: summary.segmentDataOffset,
            timestampScaleNs: summary.timestampScaleNs,
            totalDuration: summary.durationSeconds,
            fileSize: Int64(fixture.bytes.count),
            targetDuration: 6
        )
        let playlist = LocalRemuxPlaylistBuilder.makeMediaPlaylist(timeline: timeline)
        let extinf = extinfDurations(in: playlist)

        XCTAssertEqual(extinf.reduce(0, +), 24, accuracy: 1e-6)
        XCTAssertEqual(timeline.totalDuration, 24, accuracy: 1e-6)
        XCTAssertEqual(playlist.split(separator: "\n").map(String.init).last, "#EXT-X-ENDLIST")
    }
}
