#if canImport(UIKit)
import XCTest
import Foundation
import CRemuxCore
@testable import LocalRemux

/// Pure-logic tests for the precise prepare-failure reporting. When a cold device
/// play can't stand up the local remux engine, the silent fallback to server HLS
/// captures `String(describing: error)` — these tests pin that string so the
/// reason (which libavformat stage failed + the network cause) is actionable
/// instead of an opaque "demux failed".
final class RemuxOpenErrorTests: XCTestCase {

    // MARK: - Stage labels (mirror plozz_remux_stage)

    func testStageLabelsMatchCStages() {
        XCTAssertEqual(RemuxOpenError.stageLabel(Int(PLOZZ_REMUX_STAGE_ALLOC.rawValue)), "alloc")
        XCTAssertEqual(RemuxOpenError.stageLabel(Int(PLOZZ_REMUX_STAGE_OPEN_INPUT.rawValue)), "avformat_open_input")
        XCTAssertEqual(RemuxOpenError.stageLabel(Int(PLOZZ_REMUX_STAGE_FIND_STREAM_INFO.rawValue)), "avformat_find_stream_info")
        XCTAssertEqual(RemuxOpenError.stageLabel(Int(PLOZZ_REMUX_STAGE_NO_VIDEO.rawValue)), "no video stream")
        XCTAssertEqual(RemuxOpenError.stageLabel(Int(PLOZZ_REMUX_STAGE_EMPTY_SEGMENTS.rawValue)), "empty segment table")
    }

    func testStageLabelUnknownIsLabelled() {
        XCTAssertEqual(RemuxOpenError.stageLabel(99), "unknown(99)")
    }

    // MARK: - describe()

    /// The most common cold-play failure: a stale/absent token → HTTP 401 on the
    /// very first ranged read, so avformat_open_input can't even probe. The HTTP
    /// reason must win so the screenshot reads "...avformat_open_input (HTTP 401)".
    func testHTTPReasonIsPreferredAndPinpointsAuth() {
        let stage = Int(PLOZZ_REMUX_STAGE_OPEN_INPUT.rawValue)
        let desc = RemuxOpenError.describe(stage: stage, averror: -5, httpReason: "HTTP 401")
        XCTAssertEqual(desc, "local remux open failed at avformat_open_input (HTTP 401)")
    }

    /// A genuine parse/format failure (bytes arrived, libavformat rejected them):
    /// no network reason, so the AVERROR is surfaced for triage.
    func testAVERRORShownWhenNoHTTPReason() {
        let stage = Int(PLOZZ_REMUX_STAGE_FIND_STREAM_INFO.rawValue)
        let desc = RemuxOpenError.describe(stage: stage, averror: -1414092869, httpReason: nil)
        XCTAssertEqual(desc, "local remux open failed at avformat_find_stream_info (AVERROR -1414092869)")
    }

    func testEmptyHTTPReasonFallsBackToAVERROR() {
        let stage = Int(PLOZZ_REMUX_STAGE_OPEN_INPUT.rawValue)
        let desc = RemuxOpenError.describe(stage: stage, averror: -5, httpReason: "")
        XCTAssertEqual(desc, "local remux open failed at avformat_open_input (AVERROR -5)")
    }

    func testNoReasonAndNoAVERRORStillNamesStage() {
        let stage = Int(PLOZZ_REMUX_STAGE_NO_VIDEO.rawValue)
        let desc = RemuxOpenError.describe(stage: stage, averror: 0, httpReason: nil)
        XCTAssertEqual(desc, "local remux open failed at no video stream")
    }

    func testTransportErrorReasonIsCarried() {
        // A URLError (offline / TLS) is captured as "<domain> <code>: <message>".
        let stage = Int(PLOZZ_REMUX_STAGE_OPEN_INPUT.rawValue)
        let desc = RemuxOpenError.describe(
            stage: stage, averror: -5,
            httpReason: "NSURLErrorDomain -1009: The Internet connection appears to be offline."
        )
        XCTAssertEqual(
            desc,
            "local remux open failed at avformat_open_input (NSURLErrorDomain -1009: The Internet connection appears to be offline.)"
        )
    }

    /// `RemuxOpenError` is what propagates out of `buildComponents`, so its
    /// `String(describing:)` (what the silent-fallback catch records) must be the
    /// readable description, not the synthesised struct form.
    func testDescribingErrorUsesReadableDescription() {
        let error = RemuxOpenError(stage: Int(PLOZZ_REMUX_STAGE_OPEN_INPUT.rawValue),
                                   averror: -5, httpReason: "HTTP 403")
        XCTAssertEqual(String(describing: error),
                       "local remux open failed at avformat_open_input (HTTP 403)")
    }

    // MARK: - FullTimelineVODError

    func testFullTimelineVODErrorDescriptionsAreReadable() {
        XCTAssertEqual(String(describing: FullTimelineVODError.emptySegments),
                       "local remux produced an empty segment table")
        XCTAssertEqual(String(describing: FullTimelineVODError.dualLayerDolbyVision),
                       "local remux refused dual-layer Dolby Vision (Profile 7) — stays on mpv")
        XCTAssertEqual(String(describing: FullTimelineVODError.serverUnavailable),
                       "local remux loopback origin could not start")
    }
}
#endif
