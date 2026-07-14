import Foundation

/// Failures raised by the pure-Swift NFSv3 client. `MediaTransportNFS` maps these
/// onto the neutral `MediaTransportError` vocabulary (see `mapNFSError`), so the
/// rest of Plozz never sees NFS-specific error types.
public enum NFSError: Error, Equatable, Sendable {
    /// The socket could not connect, was reset, or dropped mid-exchange.
    case connectionFailed
    /// A request exceeded its deadline.
    case timeout
    /// The operation was cancelled (structured concurrency / shutdown).
    case cancelled
    /// The server's reply was truncated, misframed, or otherwise unparseable.
    case malformedResponse
    /// The RPC layer rejected the call (auth error, program/version mismatch).
    /// `authError` distinguishes a credential problem from a transport fault.
    case rpcDenied(authError: Bool)
    /// A portmap/MOUNT/NFS program returned a protocol-level status code.
    case status(NFSStatus)
    /// The requested export could not be mounted (MOUNT returned an error).
    case mountFailed(NFSStatus)
    /// A response field violated a size/shape invariant the client enforces.
    case invalidArgument
}

/// NFSv3 (`nfsstat3`, RFC 1813 §2.6) plus the MOUNT status codes that share the
/// same numeric space for the errors we surface. Only the members the read-only
/// client can encounter are enumerated by name; anything else is `.other`.
public enum NFSStatus: Equatable, Sendable {
    case ok
    case perm            // NFS3ERR_PERM     = 1
    case noEntry         // NFS3ERR_NOENT    = 2
    case io              // NFS3ERR_IO       = 5
    case accessDenied    // NFS3ERR_ACCES    = 13
    case notDirectory    // NFS3ERR_NOTDIR   = 20
    case isDirectory     // NFS3ERR_ISDIR    = 21
    case invalidArgument // NFS3ERR_INVAL    = 22
    case nameTooLong     // NFS3ERR_NAMETOOLONG = 63
    case stale           // NFS3ERR_STALE    = 70
    case notSupported    // NFS3ERR_NOTSUPP  = 10004
    case serverFault     // NFS3ERR_SERVERFAULT = 10006
    case other(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .ok
        case 1: self = .perm
        case 2: self = .noEntry
        case 5: self = .io
        case 13: self = .accessDenied
        case 20: self = .notDirectory
        case 21: self = .isDirectory
        case 22: self = .invalidArgument
        case 63: self = .nameTooLong
        case 70: self = .stale
        case 10004: self = .notSupported
        case 10006: self = .serverFault
        default: self = .other(rawValue)
        }
    }
}
