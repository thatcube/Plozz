import Foundation
import MediaTransportCore

/// A thrown SFTP `SSH_FXP_STATUS` result carrying its code so the transport can
/// map it to a protocol-neutral ``MediaTransportError`` (and so a benign
/// end-of-file status can be distinguished from a real error at the read site).
struct SFTPStatusError: Error, Equatable {
    let code: SFTP.StatusCode
}

/// Maps an SFTP status code to a protocol-neutral ``MediaTransportError``.
/// `EOF` is intentionally not mapped here — it is a normal end-of-stream signal
/// handled at the read call site, never surfaced as an error.
func mapSFTPStatus(_ code: SFTP.StatusCode) -> MediaTransportError {
    switch code {
    case .ok, .eof:
        // Neither is an error; callers handle these before mapping. Treated as a
        // protocol violation if one somehow reaches here.
        return .protocolViolation(reason: "unexpected SFTP status")
    case .noSuchFile:
        return .invalidInput(reason: "no such SFTP file")
    case .permissionDenied:
        return .permissionDenied
    case .noConnection, .connectionLost:
        return .timeout
    case .operationUnsupported:
        return .unsupportedCapability("SFTP operation")
    case .failure, .badMessage, .unknown:
        return .transport(code: Int(code.rawValue))
    }
}

/// Normalizes any error thrown along the SFTP path into a ``MediaTransportError``
/// so `ShareTransportBrowser`'s transient-vs-terminal classification behaves the
/// same as it does for SMB/WebDAV.
func mapSFTPError(_ error: Error) -> MediaTransportError {
    if let transportError = error as? MediaTransportError {
        return transportError
    }
    if let statusError = error as? SFTPStatusError {
        return mapSFTPStatus(statusError.code)
    }
    if error is CancellationError {
        return .cancelled
    }
    return .transport(code: (error as NSError).code)
}
