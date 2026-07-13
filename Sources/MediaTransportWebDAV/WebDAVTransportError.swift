import Foundation
import MediaTransportCore
import MediaTransportHTTP

/// Translates the HTTP-adapter-boundary ``TransportError`` (and stray
/// `URLError`s / `CancellationError`s) into the protocol-neutral
/// ``MediaTransportError`` the rest of Plozz reasons about.
///
/// The classification is deliberate: `ProviderShare.ShareTransportBrowser`
/// only *reconnects* on `.transport`/`.timeout` (and non-`MediaTransportError`
/// errors) and treats everything else as terminal. So a permanent
/// security/policy/auth/range rejection must map to a terminal case (never
/// `.transport`/`.timeout`), or the browser would retry-loop against a failure
/// that can never succeed; and a genuinely transient socket/timeout/5xx must
/// map to a reconnectable case so a blip self-heals. Every one of the
/// `TransportError` cases is handled explicitly — no `default` — so adding a
/// case to the primitive forces a conscious classification here.
func mapWebDAVError(_ error: Error) -> MediaTransportError {
    if let mapped = error as? MediaTransportError {
        return mapped
    }
    if error is CancellationError {
        return .cancelled
    }
    guard let transportError = error as? TransportError else {
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .transport(code: urlError.code.rawValue)
        }
        return .transport(code: (error as NSError).code)
    }

    switch transportError {
    case .cancelled:
        return .cancelled

    // Genuinely transient — reconnectable.
    case .transport(let code):
        return .transport(code: code)

    // Auth: terminal. A 401/scheme/cleartext rejection won't succeed on retry;
    // the user must fix credentials or security.
    case .authenticationFailed,
         .authenticationSchemeNotPermitted,
         .cleartextCredentialRejected:
        return .authentication(reason: transportError.description)

    // TLS trust: terminal.
    case .trustEvaluationFailed, .trustPinMismatch:
        return .trust(reason: transportError.description)

    // Resource identity drift (mid-read or precondition) — terminal; a retry
    // would just re-read a resource that no longer matches what was probed.
    case .sourceChanged, .rangeValidationFailed:
        return .sourceChanged(reason: transportError.description)

    // Range/seek unsupported by the server for this resource — terminal.
    case .rangeNotSupported, .seekableRequiresStrongETag:
        return .unsupportedRange(reason: transportError.description)

    // Protocol/policy/config violations — terminal. Retrying can't fix a
    // cross-origin redirect, a root escape, an oversized/over-count response,
    // a malformed body, a bad origin, or a session-config mismatch.
    case .invalidOrigin,
         .crossOriginRedirectRejected,
         .insecureRedirectDowngradeRejected,
         .tooManyRedirects,
         .sessionConfigurationMismatch,
         .malformedMultistatus,
         .responseTooLarge,
         .tooManyEntries,
         .pathEscapesRoot:
        return .protocolViolation(reason: transportError.description)

    // An HTTP status the client surfaced as a protocol error: classify by code
    // so transient server states reconnect and permanent ones stay terminal.
    case .protocolError(let status, _):
        return mapWebDAVHTTPStatus(status)
    }
}

/// Maps a surfaced HTTP status code to a protocol-neutral error, splitting
/// transient (reconnectable) from permanent (terminal).
func mapWebDAVHTTPStatus(_ status: Int) -> MediaTransportError {
    switch status {
    case 401:
        return .authentication(reason: "unauthorized (401)")
    case 403:
        return .permissionDenied
    case 408, 504:
        return .timeout
    case 423, 429, 507:
        return .resourceBusy
    case 500...599:
        // Transient server-side failure — allow a reconnect.
        return .transport(code: status)
    default:
        return .protocolViolation(reason: "unexpected HTTP status \(status)")
    }
}
