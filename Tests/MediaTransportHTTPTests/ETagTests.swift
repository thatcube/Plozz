import XCTest
@testable import MediaTransportHTTP

final class ETagTests: XCTestCase {
    func testStrongETagParses() {
        let etag = ETag(headerValue: "\"abc123\"")
        XCTAssertEqual(etag?.opaqueTag, "abc123")
        XCTAssertEqual(etag?.isWeak, false)
        XCTAssertTrue(etag?.isValidStrongValidator ?? false)
    }

    func testWeakETagParses() {
        let etag = ETag(headerValue: "W/\"abc123\"")
        XCTAssertEqual(etag?.opaqueTag, "abc123")
        XCTAssertEqual(etag?.isWeak, true)
    }

    func testWeakETagIsNotAValidStrongValidator() {
        let etag = ETag(headerValue: "W/\"abc123\"")
        XCTAssertFalse(etag?.isValidStrongValidator ?? true)
    }

    func testMissingETagHeaderReturnsNil() {
        XCTAssertNil(ETag(headerValue: ""))
        XCTAssertNil(ETag(headerValue: "   "))
    }

    func testUnquotedETagIsMalformed() {
        XCTAssertNil(ETag(headerValue: "abc123"))
    }

    func testETagWithEmbeddedQuoteIsMalformed() {
        XCTAssertNil(ETag(headerValue: "\"abc\"123\""))
    }

    func testETagWithWhitespaceOrControlCharactersIsMalformed() {
        XCTAssertNil(ETag(headerValue: "\"abc 123\""))
        XCTAssertNil(ETag(headerValue: "\"abc\r\nInjected: value\""))
    }

    func testETagRawValuePreservesOriginalHeaderText() {
        let etag = ETag(headerValue: "\"abc123\"")
        XCTAssertEqual(etag?.rawValue, "\"abc123\"")
    }
}
