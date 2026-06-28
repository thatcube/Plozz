#if canImport(UIKit)
import XCTest
@testable import LocalRemux

/// Pure-logic tests for `RemuxRoute` — the request-path → resource mapping the
/// server's "never 404 a declared segment" guarantee rides on. A misparse here
/// would 404 a segment AVPlayer declared in the VOD playlist and freeze the seek.
final class RemuxRouteTests: XCTestCase {

    func testParsePlaylists() {
        XCTAssertEqual(RemuxRoute.parse(path: "/master.m3u8"), .master)
        XCTAssertEqual(RemuxRoute.parse(path: "/media.m3u8"), .media)
        XCTAssertEqual(RemuxRoute.parse(path: "/init.mp4"), .initSegment)
    }

    func testParseSegments() {
        XCTAssertEqual(RemuxRoute.parse(path: "/seg0.m4s"), .segment(0))
        XCTAssertEqual(RemuxRoute.parse(path: "/seg1.m4s"), .segment(1))
        XCTAssertEqual(RemuxRoute.parse(path: "/seg1234.m4s"), .segment(1234))
    }

    func testParseToleratesLeadingPathAndQuery() {
        XCTAssertEqual(RemuxRoute.parse(path: "seg7.m4s"), .segment(7))
        XCTAssertEqual(RemuxRoute.parse(path: "/v/seg7.m4s?token=abc"), .segment(7))
        XCTAssertEqual(RemuxRoute.parse(path: "/master.m3u8?x=1"), .master)
    }

    func testParseRejectsUnknown() {
        XCTAssertNil(RemuxRoute.parse(path: "/favicon.ico"))
        XCTAssertNil(RemuxRoute.parse(path: "/seg.m4s"))      // no index
        XCTAssertNil(RemuxRoute.parse(path: "/segX.m4s"))     // non-numeric
        XCTAssertNil(RemuxRoute.parse(path: "/seg-1.m4s"))    // negative
        XCTAssertNil(RemuxRoute.parse(path: "/seg0.ts"))      // wrong extension
        XCTAssertNil(RemuxRoute.parse(path: "/"))
    }

    func testResourceNameRoundTrips() {
        XCTAssertEqual(RemuxRoute.master.resourceName, "master.m3u8")
        XCTAssertEqual(RemuxRoute.media.resourceName, "media.m3u8")
        XCTAssertEqual(RemuxRoute.initSegment.resourceName, "init.mp4")
        XCTAssertEqual(RemuxRoute.segment(9).resourceName, "seg9.m4s")
        // name → parse → name is stable for every route.
        for route in [RemuxRoute.master, .media, .initSegment, .segment(0), .segment(57)] {
            XCTAssertEqual(RemuxRoute.parse(path: "/" + route.resourceName), route)
        }
    }

    func testContentTypes() {
        XCTAssertEqual(RemuxRoute.master.contentType, "application/vnd.apple.mpegurl")
        XCTAssertEqual(RemuxRoute.media.contentType, "application/vnd.apple.mpegurl")
        XCTAssertEqual(RemuxRoute.initSegment.contentType, "video/mp4")
        XCTAssertEqual(RemuxRoute.segment(3).contentType, "video/mp4")
    }
}
#endif
