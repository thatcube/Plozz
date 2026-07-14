import XCTest
@testable import TransportNFS

// MARK: - Test doubles

/// A stub RPC connection that maps each request to a reply via a closure. The
/// whole XDR/RPC/NFS decode path runs against these canned bytes — no socket.
final class StubRPCConnection: RPCConnection, @unchecked Sendable {
    private let handler: @Sendable (Data) -> Data
    private(set) var closed = false

    init(handler: @escaping @Sendable (Data) -> Data) {
        self.handler = handler
    }

    func exchange(_ message: Data) async throws -> Data { handler(message) }
    func close() async { closed = true }
}

/// A scripted RPC server: routes a connection to a per-(program, procedure)
/// handler, dispatched on the parsed call. Models a real portmap → mountd → nfsd
/// exchange so the full client stack can be proven offline.
struct ScriptedRPCFactory: RPCConnectionFactory {
    let route: @Sendable (_ port: UInt16, _ call: ParsedRPCCall) -> Data

    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any RPCConnection {
        let route = self.route
        return StubRPCConnection { message in
            let call = ParsedRPCCall(message: message)
            return route(port, call)
        }
    }
}

/// A parsed ONC-RPC call: the fields the test server needs plus a decoder
/// positioned at the procedure arguments.
struct ParsedRPCCall {
    let xid: UInt32
    let program: UInt32
    let procedure: UInt32
    var arguments: XDRDecoder

    init(message: Data) {
        var decoder = XDRDecoder(message)
        xid = (try? decoder.decodeUInt32()) ?? 0
        _ = try? decoder.decodeUInt32()            // msg type (CALL)
        _ = try? decoder.decodeUInt32()            // rpcvers
        program = (try? decoder.decodeUInt32()) ?? 0
        _ = try? decoder.decodeUInt32()            // version
        procedure = (try? decoder.decodeUInt32()) ?? 0
        _ = try? decoder.decodeUInt32()            // cred flavor
        _ = try? decoder.decodeOpaque()            // cred body
        _ = try? decoder.decodeUInt32()            // verf flavor
        _ = try? decoder.decodeOpaque()            // verf body
        arguments = decoder
    }
}

// MARK: - Wire builders

enum Wire {
    /// Wraps procedure result bytes in an accepted RPC reply echoing `xid`.
    static func acceptedReply(xid: UInt32, results: Data) -> Data {
        var e = XDREncoder()
        e.encode(xid)
        e.encode(RPCConstants.reply)
        e.encode(RPCConstants.messageAccepted)
        e.encode(RPCConstants.authNone)   // verf flavor
        e.encodeOpaque(Data())            // verf body
        e.encode(RPCConstants.success)    // accept_stat
        e.data.append(results)
        return e.data
    }

    static func deniedAuthReply(xid: UInt32) -> Data {
        var e = XDREncoder()
        e.encode(xid)
        e.encode(RPCConstants.reply)
        e.encode(RPCConstants.messageDenied)
        e.encode(RPCConstants.authError)
        e.encode(UInt32(1))  // auth_stat
        return e.data
    }

    /// An 84-byte `fattr3`.
    static func fattr3(
        type: UInt32,
        size: UInt64,
        fileID: UInt64,
        fsID: UInt64 = 7,
        mtimeSeconds: UInt32
    ) -> Data {
        var e = XDREncoder()
        e.encode(type)
        e.encode(UInt32(0o644))   // mode
        e.encode(UInt32(1))       // nlink
        e.encode(UInt32(0))       // uid
        e.encode(UInt32(0))       // gid
        e.encode(size)            // size
        e.encode(size)            // used
        e.encode(UInt32(0))       // rdev.specdata1
        e.encode(UInt32(0))       // rdev.specdata2
        e.encode(fsID)            // fsid
        e.encode(fileID)          // fileid
        e.encode(UInt32(11)); e.encode(UInt32(0))          // atime
        e.encode(mtimeSeconds); e.encode(UInt32(0))        // mtime
        e.encode(UInt32(22)); e.encode(UInt32(0))          // ctime
        return e.data
    }

    static func fileHandle(_ bytes: [UInt8]) -> Data {
        var e = XDREncoder()
        e.encodeOpaque(Data(bytes))
        return e.data
    }

    /// Appends one `entryplus3` (its leading `value_follows` bool included).
    static func appendEntry(
        _ e: inout XDREncoder,
        fileID: UInt64,
        name: String,
        cookie: UInt64,
        type: UInt32,
        size: UInt64 = 0,
        mtime: UInt32 = 0
    ) {
        e.encode(true)                 // value_follows
        e.encode(fileID)
        e.encodeString(name)
        e.encode(cookie)
        e.encode(true)                 // name_attributes present
        e.data.append(Wire.fattr3(type: type, size: size, fileID: fileID, mtimeSeconds: mtime))
        e.encode(false)                // name_handle absent
    }
}

final class XDRTests: XCTestCase {
    func testUnsignedRoundTrip() throws {
        var e = XDREncoder()
        e.encode(UInt32(0xDEAD_BEEF))
        e.encode(UInt64(0x0102_0304_0506_0708))
        e.encode(true)
        var d = XDRDecoder(e.data)
        XCTAssertEqual(try d.decodeUInt32(), 0xDEAD_BEEF)
        XCTAssertEqual(try d.decodeUInt64(), 0x0102_0304_0506_0708)
        XCTAssertTrue(try d.decodeBool())
        XCTAssertTrue(d.isAtEnd)
    }

    func testOpaquePaddingRoundTrip() throws {
        var e = XDREncoder()
        e.encodeOpaque(Data([1, 2, 3]))     // 3 bytes -> padded to 4
        e.encode(UInt32(99))
        // 4 (len) + 4 (padded payload) + 4 (uint32) = 12
        XCTAssertEqual(e.data.count, 12)
        var d = XDRDecoder(e.data)
        XCTAssertEqual(try d.decodeOpaque(), Data([1, 2, 3]))
        XCTAssertEqual(try d.decodeUInt32(), 99)
    }

    func testStringRoundTrip() throws {
        var e = XDREncoder()
        e.encodeString("/volume1/media")
        var d = XDRDecoder(e.data)
        XCTAssertEqual(try d.decodeString(), "/volume1/media")
    }

    func testTruncatedBufferThrows() {
        var e = XDREncoder()
        e.encode(UInt32(1))
        var d = XDRDecoder(e.data)
        XCTAssertEqual(try d.decodeUInt32(), 1)
        XCTAssertThrowsError(try d.decodeUInt32()) { error in
            XCTAssertEqual(error as? NFSError, .malformedResponse)
        }
    }

    func testFixedOpaqueSkipsPadding() throws {
        var e = XDREncoder()
        e.encodeFixedOpaque(Data([0xAA, 0xBB]))  // 2 bytes -> padded to 4
        e.encode(UInt32(5))
        var d = XDRDecoder(e.data)
        XCTAssertEqual(try d.decodeFixedOpaque(2), Data([0xAA, 0xBB]))
        XCTAssertEqual(try d.decodeUInt32(), 5)
    }
}

final class RPCClientTests: XCTestCase {
    func testCallReturnsResultsDecoder() async throws {
        let connection = StubRPCConnection { message in
            let call = ParsedRPCCall(message: message)
            var results = XDREncoder()
            results.encode(UInt32(42))
            return Wire.acceptedReply(xid: call.xid, results: results.data)
        }
        let client = RPCClient(connection: connection)
        var decoder = try await client.call(
            program: 100_000, version: 2, procedure: 3, credential: .none, arguments: Data()
        )
        XCTAssertEqual(try decoder.decodeUInt32(), 42)
    }

    func testDeniedReplyThrowsAuthError() async {
        let connection = StubRPCConnection { message in
            Wire.deniedAuthReply(xid: ParsedRPCCall(message: message).xid)
        }
        let client = RPCClient(connection: connection)
        do {
            _ = try await client.call(program: 1, version: 1, procedure: 1, credential: .none, arguments: Data())
            XCTFail("expected denial")
        } catch {
            XCTAssertEqual(error as? NFSError, .rpcDenied(authError: true))
        }
    }

    func testXIDMismatchThrows() async {
        let connection = StubRPCConnection { _ in
            var results = XDREncoder()
            results.encode(UInt32(0))
            return Wire.acceptedReply(xid: 0xFFFF_FFFF, results: results.data)  // wrong xid
        }
        let client = RPCClient(connection: connection)
        do {
            _ = try await client.call(program: 1, version: 1, procedure: 1, credential: .none, arguments: Data())
            XCTFail("expected malformed")
        } catch {
            XCTAssertEqual(error as? NFSError, .malformedResponse)
        }
    }

    func testAuthUnixCredentialEncodes() throws {
        let credential = AuthUnixCredential(stamp: 1, machineName: "plozz", uid: 0, gid: 0, auxiliaryGIDs: [])
        var d = XDRDecoder(credential.encodedBody())
        XCTAssertEqual(try d.decodeUInt32(), 1)          // stamp
        XCTAssertEqual(try d.decodeString(), "plozz")    // machinename
        XCTAssertEqual(try d.decodeUInt32(), 0)          // uid
        XCTAssertEqual(try d.decodeUInt32(), 0)          // gid
        XCTAssertEqual(try d.decodeUInt32(), 0)          // aux gid count
    }
}

final class NFSProcedureTests: XCTestCase {
    private func client(_ handler: @escaping @Sendable (ParsedRPCCall) -> Data) -> RPCClient {
        RPCClient(connection: StubRPCConnection { handler(ParsedRPCCall(message: $0)) })
    }

    func testGetAttributesDecodesFattr3() async throws {
        let client = client { call in
            var results = XDREncoder()
            results.encode(UInt32(0))  // NFS3_OK
            results.data.append(Wire.fattr3(type: 1, size: 4096, fileID: 99, mtimeSeconds: 1000))
            return Wire.acceptedReply(xid: call.xid, results: results.data)
        }
        let attributes = try await NFSProcedures.getAttributes(
            client: client, credential: .default, handle: NFSFileHandle(bytes: Data([1]))
        )
        XCTAssertEqual(attributes.type, .regular)
        XCTAssertEqual(attributes.size, 4096)
        XCTAssertEqual(attributes.fileID, 99)
        XCTAssertEqual(attributes.modifiedAt, Date(timeIntervalSince1970: 1000))
    }

    func testGetAttributesMapsStatusToError() async {
        let client = client { call in
            var results = XDREncoder()
            results.encode(UInt32(13))  // NFS3ERR_ACCES
            return Wire.acceptedReply(xid: call.xid, results: results.data)
        }
        do {
            _ = try await NFSProcedures.getAttributes(
                client: client, credential: .default, handle: NFSFileHandle(bytes: Data([1]))
            )
            XCTFail("expected status error")
        } catch {
            XCTAssertEqual(error as? NFSError, .status(.accessDenied))
        }
    }

    func testLookupReturnsHandleAndAttributes() async throws {
        let client = client { call in
            var results = XDREncoder()
            results.encode(UInt32(0))                       // status
            results.data.append(Wire.fileHandle([9, 9, 9])) // object fh
            results.encode(true)                            // obj attrs present
            results.data.append(Wire.fattr3(type: 2, size: 0, fileID: 5, mtimeSeconds: 42))
            results.encode(false)                           // dir attrs absent
            return Wire.acceptedReply(xid: call.xid, results: results.data)
        }
        let result = try await NFSProcedures.lookup(
            client: client, credential: .default, directory: NFSFileHandle(bytes: Data([0])), name: "Movies"
        )
        XCTAssertEqual(result.handle.bytes, Data([9, 9, 9]))
        XCTAssertEqual(result.attributes?.type, .directory)
        XCTAssertEqual(result.attributes?.fileID, 5)
    }

    func testReadReturnsDataAndEOF() async throws {
        let payload = Data((0..<10).map { UInt8($0) })
        let client = client { call in
            var results = XDREncoder()
            results.encode(UInt32(0))     // status
            results.encode(false)         // file attrs absent
            results.encode(UInt32(payload.count))  // count
            results.encode(true)          // eof
            results.encodeOpaque(payload) // data
            return Wire.acceptedReply(xid: call.xid, results: results.data)
        }
        let result = try await NFSProcedures.read(
            client: client, credential: .default,
            handle: NFSFileHandle(bytes: Data([1])), offset: 0, count: 512
        )
        XCTAssertEqual(result.data, payload)
        XCTAssertTrue(result.eof)
    }

    func testReadDirectorySkipsDotEntriesAndFollowsEOF() async throws {
        let client = client { call in
            var results = XDREncoder()
            results.encode(UInt32(0))                 // status
            results.encode(false)                     // dir attrs absent
            results.encodeFixedOpaque(Data(count: 8)) // cookieverf
            // entry "." (skipped)
            Wire.appendEntry(&results, fileID: 1, name: ".", cookie: 1, type: 2)
            // entry "Movie.mkv"
            Wire.appendEntry(&results, fileID: 2, name: "Movie.mkv", cookie: 2, type: 1, size: 1234, mtime: 55)
            results.encode(false)  // no more entries
            results.encode(true)   // eof
            return Wire.acceptedReply(xid: call.xid, results: results.data)
        }
        let entries = try await NFSProcedures.readDirectory(
            client: client, credential: .default,
            directory: NFSFileHandle(bytes: Data([0])), maxCount: 65_536
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "Movie.mkv")
        XCTAssertEqual(entries.first?.attributes?.size, 1234)
    }
}

/// End-to-end: portmap → mountd → nfsd, proving mount + browse + read compose.
final class NFSClientIntegrationTests: XCTestCase {
    private static let mountdPort: UInt16 = 635
    private static let rootHandle: [UInt8] = [0xAA, 0xBB]
    private static let fileHandle: [UInt8] = [0xCC, 0xDD]

    private func makeFactory() -> ScriptedRPCFactory {
        ScriptedRPCFactory { port, call in
            switch port {
            case NFSWellKnownPort.portmap:
                // GETPORT: return mountd's port for the mount program, else nfsd.
                var args = call.arguments
                let requestedProgram = (try? args.decodeUInt32()) ?? 0
                var results = XDREncoder()
                let resolved = requestedProgram == NFSProgram.mount
                    ? Self.mountdPort : NFSWellKnownPort.nfs
                results.encode(UInt32(resolved))
                return Wire.acceptedReply(xid: call.xid, results: results.data)

            case Self.mountdPort:
                // MNT: status OK + root handle + one auth flavor.
                var results = XDREncoder()
                results.encode(UInt32(0))
                results.data.append(Wire.fileHandle(Self.rootHandle))
                results.encode(UInt32(1))                     // auth flavor count
                results.encode(RPCConstants.authUnix)
                return Wire.acceptedReply(xid: call.xid, results: results.data)

            case NFSWellKnownPort.nfs:
                return Self.nfsReply(call)

            default:
                return Wire.acceptedReply(xid: call.xid, results: Data())
            }
        }
    }

    private static func nfsReply(_ call: ParsedRPCCall) -> Data {
        var results = XDREncoder()
        switch call.procedure {
        case NFSProcedure.fsInfo:
            results.encode(UInt32(0))     // status
            results.encode(false)         // obj attrs absent
            results.encode(UInt32(1 << 20))  // rtmax
            results.encode(UInt32(1 << 17))  // rtpref
        case NFSProcedure.getAttr:
            results.encode(UInt32(0))
            results.data.append(Wire.fattr3(type: 2, size: 0, fileID: 1, mtimeSeconds: 10))
        case NFSProcedure.lookup:
            results.encode(UInt32(0))
            results.data.append(Wire.fileHandle(fileHandle))
            results.encode(true)
            results.data.append(Wire.fattr3(type: 1, size: 2048, fileID: 2, mtimeSeconds: 99))
            results.encode(false)
        case NFSProcedure.read:
            let payload = Data(repeating: 0x5A, count: 2048)
            results.encode(UInt32(0))
            results.encode(false)
            results.encode(UInt32(payload.count))
            results.encode(true)
            results.encodeOpaque(payload)
        default:
            results.encode(UInt32(0))
        }
        return Wire.acceptedReply(xid: call.xid, results: results.data)
    }

    func testMountResolvesRootAndReadsFile() async throws {
        let client = NFSClient(
            host: "nas.local",
            credential: .default,
            timeout: .seconds(5),
            connectionFactory: makeFactory()
        )
        let session = try await client.mount(exportPath: "/volume1/media")

        let root = try await session.rootAttributes()
        XCTAssertTrue(root.isDirectory)

        let (handle, attributes) = try await session.resolve(relativePath: "Movie.mkv")
        XCTAssertEqual(handle.bytes, Data(Self.fileHandle))
        XCTAssertEqual(attributes.size, 2048)

        let reader = try await session.openReader(handle: handle, byteSize: 2048)
        let data = try await reader.read(offset: 0, length: 2048)
        XCTAssertEqual(data.count, 2048)
        await reader.close()
        await session.shutdown()
    }
}
