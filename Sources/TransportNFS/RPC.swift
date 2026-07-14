import Foundation

/// ONC-RPC v2 (RFC 5531) message construction and reply parsing, plus the
/// `AUTH_UNIX`/`AUTH_NONE` credential flavors NFSv3 uses.
///
/// The transport (socket) is abstracted behind ``RPCConnection`` so the entire
/// call/reply/credential path can be exercised offline against canned reply
/// bytes — the same discipline the WebDAV adapter uses with a stubbed
/// `URLProtocol` and SMB uses with a stubbed `SMBTransportBackend`.
enum RPCConstants {
    static let version: UInt32 = 2

    // msg_type
    static let call: UInt32 = 0
    static let reply: UInt32 = 1

    // reply_stat
    static let messageAccepted: UInt32 = 0
    static let messageDenied: UInt32 = 1

    // accept_stat
    static let success: UInt32 = 0
    static let programUnavailable: UInt32 = 1
    static let programMismatch: UInt32 = 2
    static let procedureUnavailable: UInt32 = 3
    static let garbageArgs: UInt32 = 4
    static let systemError: UInt32 = 5

    // reject_stat
    static let rpcMismatch: UInt32 = 0
    static let authError: UInt32 = 1

    // auth_flavor
    static let authNone: UInt32 = 0
    static let authUnix: UInt32 = 1
}

/// The `AUTH_UNIX` (a.k.a. `AUTH_SYS`) credential — uid/gid trust with no
/// password, which is exactly why the credential vault maps `.nfs` to
/// `.noCredentials`. A read-only home-NAS client presents a stable identity.
struct AuthUnixCredential: Sendable, Equatable {
    var stamp: UInt32
    var machineName: String
    var uid: UInt32
    var gid: UInt32
    var auxiliaryGIDs: [UInt32]

    /// Default identity. tvOS has no meaningful Unix uid, so this presents
    /// uid/gid 0: on the common `root_squash` export the server maps it to the
    /// anonymous user (reading world-readable media, which is the norm for a
    /// media share), and on `no_root_squash` it grants full read access. Callers
    /// can override for exports that key access off a specific uid.
    static let `default` = AuthUnixCredential(
        stamp: 0,
        machineName: "plozz",
        uid: 0,
        gid: 0,
        auxiliaryGIDs: []
    )

    /// Encodes the `authsys_parms` body carried inside the `opaque_auth`.
    func encodedBody() -> Data {
        var encoder = XDREncoder()
        encoder.encode(stamp)
        encoder.encodeString(machineName)
        encoder.encode(uid)
        encoder.encode(gid)
        encoder.encode(UInt32(auxiliaryGIDs.count))
        for gid in auxiliaryGIDs {
            encoder.encode(gid)
        }
        return encoder.data
    }
}

/// The credential presented on an RPC call.
enum RPCCredential: Sendable, Equatable {
    case none
    case unix(AuthUnixCredential)

    fileprivate var flavor: UInt32 {
        switch self {
        case .none: return RPCConstants.authNone
        case .unix: return RPCConstants.authUnix
        }
    }

    fileprivate var body: Data {
        switch self {
        case .none: return Data()
        case .unix(let credential): return credential.encodedBody()
        }
    }
}

/// A connected ONC-RPC endpoint over a stream (TCP). `exchange` sends one
/// complete RPC message and returns the matching reply, with record-marking
/// framing handled by the implementation. Serialized single-outstanding use is
/// assumed (the client awaits each reply before issuing the next call), so no
/// XID demultiplexing is required here.
protocol RPCConnection: Sendable {
    func exchange(_ message: Data) async throws -> Data
    func close() async
}

/// Builds RPC call messages and parses accepted replies, delegating the wire
/// exchange to an injected ``RPCConnection``.
struct RPCClient: Sendable {
    let connection: any RPCConnection

    /// A monotonically increasing XID source. Only used to correlate a single
    /// outstanding call with its reply; wraps harmlessly.
    private static func nextXID() -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000)) &+ UInt32.random(in: 0...UInt32.max)
    }

    /// Issues one RPC call and returns a decoder positioned at the procedure's
    /// results (i.e. immediately after the accepted-reply header).
    func call(
        program: UInt32,
        version: UInt32,
        procedure: UInt32,
        credential: RPCCredential,
        arguments: Data
    ) async throws -> XDRDecoder {
        let xid = Self.nextXID()

        var encoder = XDREncoder()
        encoder.encode(xid)
        encoder.encode(RPCConstants.call)
        encoder.encode(RPCConstants.version)
        encoder.encode(program)
        encoder.encode(version)
        encoder.encode(procedure)
        // cred
        encoder.encode(credential.flavor)
        encoder.encodeOpaque(credential.body)
        // verf — always AUTH_NONE for the calls this read-only client makes.
        encoder.encode(RPCConstants.authNone)
        encoder.encodeOpaque(Data())
        encoder.data.append(arguments)

        let replyData = try await connection.exchange(encoder.data)
        var decoder = XDRDecoder(replyData)

        let replyXID = try decoder.decodeUInt32()
        guard replyXID == xid else { throw NFSError.malformedResponse }
        let messageType = try decoder.decodeUInt32()
        guard messageType == RPCConstants.reply else { throw NFSError.malformedResponse }

        let replyStat = try decoder.decodeUInt32()
        if replyStat == RPCConstants.messageDenied {
            let rejectStat = try decoder.decodeUInt32()
            throw NFSError.rpcDenied(authError: rejectStat == RPCConstants.authError)
        }
        guard replyStat == RPCConstants.messageAccepted else {
            throw NFSError.malformedResponse
        }

        // accepted_reply: opaque_auth verf, then accept_stat.
        _ = try decoder.decodeUInt32()          // verf flavor
        _ = try decoder.decodeOpaque()          // verf body
        let acceptStat = try decoder.decodeUInt32()
        guard acceptStat == RPCConstants.success else {
            // PROG_UNAVAIL / PROG_MISMATCH / PROC_UNAVAIL / GARBAGE_ARGS /
            // SYSTEM_ERR are all PERMANENT — the server accepted the call and
            // rejected it on grounds retrying can't fix. Surface as terminal so
            // the browser doesn't reconnect-and-retry-loop.
            throw NFSError.rpcUnsupported
        }
        return decoder
    }

    func close() async {
        await connection.close()
    }
}

/// Record-marking helpers (RFC 5531 §11): a stream RPC message is one or more
/// fragments, each prefixed by a 4-byte header whose top bit marks the last
/// fragment and whose low 31 bits give the fragment length.
enum RPCRecordMarking {
    static let lastFragmentFlag: UInt32 = 0x8000_0000
    static let lengthMask: UInt32 = 0x7fff_ffff

    /// Wraps a complete message as a single last-fragment record.
    static func frame(_ message: Data) -> Data {
        var header = XDREncoder()
        header.encode(lastFragmentFlag | (UInt32(message.count) & lengthMask))
        var framed = header.data
        framed.append(message)
        return framed
    }

    /// Parses a fragment header into (isLast, fragmentLength).
    static func parseHeader(_ header: UInt32) -> (isLast: Bool, length: Int) {
        (header & lastFragmentFlag != 0, Int(header & lengthMask))
    }
}
