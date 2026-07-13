import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportHTTP
@testable import MediaTransportWebDAV
import XCTest

/// Table-driven coverage that every `TransportError` maps to a
/// `MediaTransportError` whose reconnect classification is correct for
/// `ProviderShare.ShareTransportBrowser.shouldReconnect`. Getting this wrong
/// either retry-loops a permanent failure or gives up on a transient blip, so
/// each case is pinned explicitly.
final class WebDAVTransportErrorTests: XCTestCase {
    /// Mirror of `ShareTransportBrowser.shouldReconnect` (private there): only
    /// `.timeout`/`.transport` reconnect; everything else is terminal.
    private func reconnects(_ error: MediaTransportError) -> Bool {
        switch error {
        case .timeout, .transport:
            return true
        case .invalidInput, .unsupportedCapability, .unsupportedRange,
             .authentication, .trust, .permissionDenied, .protocolViolation,
             .resourceBusy, .sourceChanged, .cancelled:
            return false
        }
    }

    /// A stable label for a `MediaTransportError`'s case, for table assertions.
    private func category(_ error: MediaTransportError) -> String {
        switch error {
        case .invalidInput: return "invalidInput"
        case .unsupportedCapability: return "unsupportedCapability"
        case .unsupportedRange: return "unsupportedRange"
        case .authentication: return "authentication"
        case .trust: return "trust"
        case .permissionDenied: return "permissionDenied"
        case .protocolViolation: return "protocolViolation"
        case .timeout: return "timeout"
        case .resourceBusy: return "resourceBusy"
        case .sourceChanged: return "sourceChanged"
        case .cancelled: return "cancelled"
        case .transport: return "transport"
        }
    }

    func testEveryTransportErrorMapsToTheExpectedCategoryAndReconnectVerdict() {
        let cases: [(TransportError, expected: String, reconnects: Bool)] = [
            (.invalidOrigin(reason: "x"), "protocolViolation", false),
            (.crossOriginRedirectRejected(from: "a", to: "b"), "protocolViolation", false),
            (.insecureRedirectDowngradeRejected(from: "a", to: "b"), "protocolViolation", false),
            (.tooManyRedirects(limit: 5), "protocolViolation", false),
            (.cleartextCredentialRejected(reason: "x"), "authentication", false),
            (.authenticationSchemeNotPermitted(scheme: "basic"), "authentication", false),
            (.authenticationFailed(reason: "x"), "authentication", false),
            (.sessionConfigurationMismatch, "protocolViolation", false),
            (.trustEvaluationFailed(reason: "x"), "trust", false),
            (.trustPinMismatch, "trust", false),
            (.malformedMultistatus(reason: "x"), "protocolViolation", false),
            (.responseTooLarge(limitBytes: 10), "protocolViolation", false),
            (.tooManyEntries(limit: 10), "protocolViolation", false),
            (.pathEscapesRoot, "protocolViolation", false),
            (.rangeNotSupported(reason: "x"), "unsupportedRange", false),
            (.seekableRequiresStrongETag, "unsupportedRange", false),
            (.rangeValidationFailed(reason: "x"), "sourceChanged", false),
            (.sourceChanged(reason: "x"), "sourceChanged", false),
            (.cancelled, "cancelled", false),
            (.transport(code: 54), "transport", true),
            // HTTP statuses surfaced as protocolError.
            (.protocolError(status: 401, detail: ""), "authentication", false),
            (.protocolError(status: 403, detail: ""), "permissionDenied", false),
            (.protocolError(status: 408, detail: ""), "timeout", true),
            (.protocolError(status: 504, detail: ""), "timeout", true),
            (.protocolError(status: 423, detail: ""), "resourceBusy", false),
            (.protocolError(status: 429, detail: ""), "resourceBusy", false),
            (.protocolError(status: 507, detail: ""), "resourceBusy", false),
            (.protocolError(status: 500, detail: ""), "transport", true),
            (.protocolError(status: 503, detail: ""), "transport", true),
            (.protocolError(status: 418, detail: ""), "protocolViolation", false),
        ]

        for (input, expected, expectedReconnects) in cases {
            let mapped = mapWebDAVError(input)
            XCTAssertEqual(category(mapped), expected, "mapping for \(input)")
            XCTAssertEqual(reconnects(mapped), expectedReconnects, "reconnect verdict for \(input)")
        }
    }

    func testNonTransportErrorsAreClassified() {
        XCTAssertEqual(category(mapWebDAVError(CancellationError())), "cancelled")
        XCTAssertEqual(category(mapWebDAVError(URLError(.timedOut))), "transport")
        XCTAssertTrue(reconnects(mapWebDAVError(URLError(.timedOut))))
        XCTAssertEqual(category(mapWebDAVError(URLError(.cancelled))), "cancelled")
        // A MediaTransportError passes through unchanged.
        XCTAssertEqual(category(mapWebDAVError(MediaTransportError.permissionDenied)), "permissionDenied")
    }
}
