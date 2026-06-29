#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Pure-logic tests for the origin's HTTP parsing helpers — full `Range:` support
/// (so AVPlayer's seek-ahead byte requests are honoured with 206/416) and
/// keep-alive detection (so the player reuses one connection for the whole
/// timeline instead of thrashing).
final class FullTimelineVODServerTests: XCTestCase {

    private func request(_ headers: String) -> String {
        "GET /seg0.m4s HTTP/1.1\r\n" + headers + "\r\n\r\n"
    }

    // MARK: - Range parsing

    func testParseRangeClosed() {
        let r = FullTimelineVODServer.parseRange(in: request("Range: bytes=0-499\r\n"))
        XCTAssertEqual(r?.start, 0)
        XCTAssertEqual(r?.end, 499)
    }

    func testParseRangeOpenEnded() {
        let r = FullTimelineVODServer.parseRange(in: request("Range: bytes=1024-\r\n"))
        XCTAssertEqual(r?.start, 1024)
        XCTAssertNil(r?.end)
    }

    func testParseRangeCaseInsensitiveHeader() {
        let r = FullTimelineVODServer.parseRange(in: request("range: bytes=10-20\r\n"))
        XCTAssertEqual(r?.start, 10)
        XCTAssertEqual(r?.end, 20)
    }

    func testParseRangeNoneWhenAbsent() {
        XCTAssertNil(FullTimelineVODServer.parseRange(in: request("Accept: */*\r\n")))
    }

    func testParseRangeRejectsMultiRange() {
        // Multi-range is unsupported → nil so the caller serves a full 200.
        XCTAssertNil(FullTimelineVODServer.parseRange(in: request("Range: bytes=0-1,2-3\r\n")))
    }

    func testParseRangeRejectsGarbage() {
        XCTAssertNil(FullTimelineVODServer.parseRange(in: request("Range: bytes=abc-def\r\n")))
    }

    // MARK: - Keep-alive

    func testKeepAliveDefaultsTrueForHTTP11() {
        XCTAssertTrue(FullTimelineVODServer.wantsKeepAlive(request("Host: 127.0.0.1\r\n")))
    }

    func testKeepAliveHonoursConnectionClose() {
        XCTAssertFalse(FullTimelineVODServer.wantsKeepAlive(request("Connection: close\r\n")))
    }

    func testKeepAliveHonoursExplicitKeepAlive() {
        XCTAssertTrue(FullTimelineVODServer.wantsKeepAlive(request("Connection: keep-alive\r\n")))
    }

    func testKeepAliveCaseInsensitive() {
        XCTAssertFalse(FullTimelineVODServer.wantsKeepAlive(request("CONNECTION: Close\r\n")))
    }
}
#endif
