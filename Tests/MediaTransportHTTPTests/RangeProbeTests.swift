import XCTest
@testable import MediaTransportHTTP

final class RangeProbeTests: XCTestCase {
    private let url = URL(string: "https://nas.example.com/dav/movies/Show.mkv")!
    private let strongETag = ETag(headerValue: "\"strong-etag-1\"")!
    private let weakETag = ETag(headerValue: "W/\"weak-etag-1\"")!

    // MARK: - probeRequest

    func testProbeRequestSendsRangeZeroZeroAndIdentityEncoding() {
        let request = RangeProbe.probeRequest(url: url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    // MARK: - validateProbe

    func testValidateProbeSucceedsOn206WithStrongETagAndMatchingContentRange() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 0-0/1000"],
            bodyLength: 1,
            resourceURL: url
        )
        switch result {
        case .success(let probe):
            XCTAssertEqual(probe.etag, strongETag)
            XCTAssertEqual(probe.totalLength, 1000)
            XCTAssertEqual(probe.resourceURL, url)
        case .failure(let error):
            XCTFail("expected success, got \(error)")
        }
    }

    func testValidateProbeRejects200() {
        let result = RangeProbe.validateProbe(
            status: 200,
            headers: ["ETag": "\"e\""],
            bodyLength: 1000,
            resourceURL: url
        )
        guard case .failure(.rangeNotSupported) = result else {
            return XCTFail("expected rangeNotSupported for 200 OK probe response")
        }
    }

    func testValidateProbeRejectsWeakETag() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["ETag": "W/\"weak-etag-1\"", "Content-Range": "bytes 0-0/1000"],
            bodyLength: 1,
            resourceURL: url
        )
        guard case .failure(.seekableRequiresStrongETag) = result else {
            return XCTFail("expected seekableRequiresStrongETag for a weak probe ETag")
        }
    }

    func testValidateProbeRejectsMissingETag() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["Content-Range": "bytes 0-0/1000"],
            bodyLength: 1,
            resourceURL: url
        )
        guard case .failure(.seekableRequiresStrongETag) = result else {
            return XCTFail("expected seekableRequiresStrongETag when ETag header is absent")
        }
    }

    func testValidateProbeRejectsMismatchedContentRange() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["ETag": "\"e\"", "Content-Range": "bytes 5-10/1000"],
            bodyLength: 1,
            resourceURL: url
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed when Content-Range doesn't echo bytes=0-0")
        }
    }

    func testValidateProbeRejectsContentEncoding() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: [
                "ETag": "\"e\"",
                "Content-Range": "bytes 0-0/1000",
                "Content-Encoding": "gzip"
            ],
            bodyLength: 1,
            resourceURL: url
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed")
        }
    }

    func testValidateProbeAcceptsCaseInsensitiveRangeUnit() {
        let result = RangeProbe.validateProbe(
            status: 206,
            headers: ["ETag": "\"e\"", "Content-Range": "Bytes 0-0/1000"],
            bodyLength: 1,
            resourceURL: url
        )
        guard case .success = result else {
            return XCTFail("expected a valid case-insensitive range unit")
        }
    }

    func testValidateProbeMaps412ToSourceChanged() {
        let result = RangeProbe.validateProbe(
            status: 412,
            headers: [:],
            bodyLength: 0,
            resourceURL: url
        )
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged for a 412 probe response")
        }
    }

    // MARK: - readRequest

    func testReadRequestSendsExactRangeIdentityEncodingAndIfMatch() {
        guard case .success(let request) = RangeProbe.readRequest(url: url, start: 100, end: 199, ifMatch: strongETag) else {
            return XCTFail("expected a valid read request")
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=100-199")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"strong-etag-1\"")
    }

    func testReadRequestRejectsInvertedRange() {
        guard case .failure(.rangeValidationFailed) = RangeProbe.readRequest(url: url, start: 200, end: 100, ifMatch: strongETag) else {
            return XCTFail("expected rangeValidationFailed for end < start")
        }
    }

    func testReadRequestRejectsNegativeStart() {
        guard case .failure(.rangeValidationFailed) = RangeProbe.readRequest(url: url, start: -1, end: 10, ifMatch: strongETag) else {
            return XCTFail("expected rangeValidationFailed for a negative start")
        }
    }

    func testReadRequestRejectsRangeExceedingMaxReadBytes() {
        let result = RangeProbe.readRequest(url: url, start: 0, end: 1_000, ifMatch: strongETag, maxReadBytes: 10)
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed when requested size exceeds maxReadBytes")
        }
    }

    func testReadRequestRejectsOverflowingRange() {
        let result = RangeProbe.readRequest(url: url, start: 0, end: Int64.max, ifMatch: strongETag)
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed for arithmetic overflow")
        }
    }

    func testReadRequestRejectsWeakETag() {
        let result = RangeProbe.readRequest(url: url, start: 0, end: 10, ifMatch: weakETag)
        guard case .failure(.seekableRequiresStrongETag) = result else {
            return XCTFail("expected seekableRequiresStrongETag when If-Match validator is weak")
        }
    }

    // MARK: - validateRead

    func testValidateReadSucceedsOnExactMatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 100-199/1000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .success = result else {
            return XCTFail("expected validateRead to succeed on an exact match")
        }
    }

    func testValidateReadRejects200() {
        let result = RangeProbe.validateRead(
            status: 200,
            headers: ["ETag": "\"strong-etag-1\""],
            bodyLength: 1000,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed when server ignores Range and returns 200")
        }
    }

    func testValidateReadRejectsContentRangeStartMismatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 0-99/1000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed on Content-Range start mismatch")
        }
    }

    func testValidateReadRejectsContentRangeEndMismatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 100-150/1000"],
            bodyLength: 51,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed on Content-Range end mismatch")
        }
    }

    func testValidateReadRejectsContentRangeTotalMismatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 100-199/2000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed on Content-Range total mismatch (source resized)")
        }
    }

    func testValidateReadRejectsBodyLengthMismatch() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"strong-etag-1\"", "Content-Range": "bytes 100-199/1000"],
            bodyLength: 42,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed when body length doesn't match the range size")
        }
    }

    func testValidateReadMapsETagMismatchToSourceChanged() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "\"different-etag\"", "Content-Range": "bytes 100-199/1000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged when the ETag no longer matches the probe")
        }
    }

    func testValidateReadMaps412ToSourceChanged() {
        let result = RangeProbe.validateRead(
            status: 412,
            headers: [:],
            bodyLength: 0,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged for a 412 Precondition Failed bounded read")
        }
    }

    func testValidateReadRejectsMissingETagOnResponse() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["Content-Range": "bytes 100-199/1000"],
            bodyLength: 100,
            expectedStart: 100,
            expectedEnd: 199,
            expectedTotal: 1000,
            expectedETag: strongETag
        )
        guard case .failure(.sourceChanged) = result else {
            return XCTFail("expected sourceChanged when the bounded-read response carries no ETag at all")
        }
    }

    func testValidateReadRejectsContentEncoding() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: [
                "ETag": "\"strong-etag-1\"",
                "Content-Range": "bytes 0-9/100",
                "Content-Encoding": "br"
            ],
            bodyLength: 10,
            expectedStart: 0,
            expectedEnd: 9,
            expectedTotal: 100,
            expectedETag: strongETag
        )
        guard case .failure(.rangeValidationFailed) = result else {
            return XCTFail("expected rangeValidationFailed")
        }
    }

    func testValidateReadRejectsWeakExpectedAndResponseETags() {
        let result = RangeProbe.validateRead(
            status: 206,
            headers: ["ETag": "W/\"weak-etag-1\"", "Content-Range": "bytes 0-9/100"],
            bodyLength: 10,
            expectedStart: 0,
            expectedEnd: 9,
            expectedTotal: 100,
            expectedETag: weakETag
        )
        guard case .failure(.seekableRequiresStrongETag) = result else {
            return XCTFail("expected seekableRequiresStrongETag")
        }
    }
}
