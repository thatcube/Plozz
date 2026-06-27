import XCTest
@testable import CoreModels

final class LocalRemuxRoutesTests: XCTestCase {
    private let session = "AB12CD34"

    func testPathFormatting() {
        XCTAssertEqual(LocalRemuxRoutes.playlistPath(session: session), "/AB12CD34/index.m3u8")
        XCTAssertEqual(LocalRemuxRoutes.initPath(session: session), "/AB12CD34/init.mp4")
        XCTAssertEqual(LocalRemuxRoutes.segmentPath(session: session, index: 7), "/AB12CD34/seg7.m4s")
    }

    func testParsePlaylist() {
        XCTAssertEqual(
            LocalRemuxRoutes.parse(path: "/AB12CD34/index.m3u8"),
            .playlist(session: session)
        )
    }

    func testParseInitSegment() {
        XCTAssertEqual(
            LocalRemuxRoutes.parse(path: "/AB12CD34/init.mp4"),
            .initSegment(session: session)
        )
    }

    func testParseMediaSegment() {
        XCTAssertEqual(
            LocalRemuxRoutes.parse(path: "/AB12CD34/seg42.m4s"),
            .mediaSegment(session: session, index: 42)
        )
    }

    func testParseIgnoresQueryString() {
        XCTAssertEqual(
            LocalRemuxRoutes.parse(path: "/AB12CD34/seg3.m4s?token=xyz"),
            .mediaSegment(session: session, index: 3)
        )
    }

    func testRoundTripsThroughFormattingAndParsing() {
        for index in [0, 1, 9, 10, 123, 9_999] {
            let path = LocalRemuxRoutes.segmentPath(session: session, index: index)
            XCTAssertEqual(LocalRemuxRoutes.parse(path: path), .mediaSegment(session: session, index: index))
        }
        XCTAssertEqual(LocalRemuxRoutes.parse(path: LocalRemuxRoutes.playlistPath(session: session)), .playlist(session: session))
        XCTAssertEqual(LocalRemuxRoutes.parse(path: LocalRemuxRoutes.initPath(session: session)), .initSegment(session: session))
    }

    func testRejectsMalformedPaths() {
        XCTAssertNil(LocalRemuxRoutes.parse(path: "/AB12CD34"))
        XCTAssertNil(LocalRemuxRoutes.parse(path: "/AB12CD34/segX.m4s"))
        XCTAssertNil(LocalRemuxRoutes.parse(path: "/AB12CD34/cover.jpg"))
        XCTAssertNil(LocalRemuxRoutes.parse(path: "/"))
        XCTAssertNil(LocalRemuxRoutes.parse(path: "/a/b/c"))
    }
}
