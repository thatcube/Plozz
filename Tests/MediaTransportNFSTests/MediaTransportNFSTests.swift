import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportNFS
import TransportNFS
import XCTest

/// A stub NFS backend so the adapter/session/filesystem/byte-source can be
/// proven without a socket — the NFS analogue of the SMB tests' `FakeSMBBackend`.
final class FakeNFSBackend: NFSTransportBackend, @unchecked Sendable {
    var connectError: Error?
    var validateError: Error?
    var listEntries: [NFSBackendEntry] = []
    var statEntry: NFSBackendEntry?
    var statError: Error?
    var smallFileData = Data()
    var sourceBytes = Data()
    private(set) var didShutdown = false
    private(set) var connectedHost: String?
    private(set) var connectedExport: String?

    func connect(host: String, exportPath: String) async throws {
        if let connectError { throw connectError }
        connectedHost = host
        connectedExport = exportPath
    }

    func validate() async throws {
        if let validateError { throw validateError }
    }

    func list(relativePath: String) async throws -> [NFSBackendEntry] {
        listEntries
    }

    func stat(relativePath: String) async throws -> NFSBackendEntry {
        if let statError { throw statError }
        guard let statEntry else { throw NFSError.status(.noEntry) }
        return statEntry
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        smallFileData
    }

    func openSource(relativePath: String, byteSize: Int64) async throws -> any MediaTransportByteSource {
        FakeByteSource(bytes: sourceBytes, byteSize: byteSize)
    }

    func shutdown() async {
        didShutdown = true
    }
}

final class FakeByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64
    private let bytes: Data

    init(bytes: Data, byteSize: Int64) {
        self.bytes = bytes
        self.byteSize = byteSize
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset < Int64(bytes.count) else { return Data() }
        let start = Int(offset)
        let end = min(start + length, bytes.count)
        return bytes.subdata(in: start..<end)
    }

    func shutdown() async {}
}

final class MediaTransportNFSTests: XCTestCase {
    private func makeKey(
        revision: CredentialRevision = CredentialRevision(),
        rootPath: String = "/volume1/media"
    ) throws -> MediaTransportSessionKey {
        MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: revision,
            endpoint: try MediaTransportEndpointIdentity(
                transportIdentifier: "nfs",
                host: "nas.local",
                port: 2049,
                rootPath: rootPath
            ),
            trustRevision: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            role: .scanner
        )
    }

    func testTransportIdentifierIsNFS() {
        XCTAssertEqual(NFSMediaTransportAdapter().transportIdentifier, "nfs")
    }

    func testConnectPassesExportPathAndListsEntries() async throws {
        let backend = FakeNFSBackend()
        backend.listEntries = [
            NFSBackendEntry(name: "Movies", kind: .directory, size: nil, modifiedAt: nil),
            NFSBackendEntry(
                name: "clip.mkv",
                kind: .file,
                size: 42,
                modifiedAt: Date(timeIntervalSince1970: 100)
            ),
        ]
        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        let session = try await adapter.connect(for: makeKey())

        XCTAssertEqual(backend.connectedHost, "nas.local")
        XCTAssertEqual(backend.connectedExport, "/volume1/media")

        let entries = try await session.fileSystem.list(relativePath: "")
        XCTAssertEqual(entries.map(\.relativePath), ["Movies", "clip.mkv"])
        XCTAssertEqual(entries[1].size, 42)
    }

    func testListNestsChildPaths() async throws {
        let backend = FakeNFSBackend()
        backend.listEntries = [
            NFSBackendEntry(
                name: "clip.mkv",
                kind: .file,
                size: 10,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
        ]
        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        let session = try await adapter.connect(for: makeKey())
        let entries = try await session.fileSystem.list(relativePath: "Movies")
        XCTAssertEqual(entries.first?.relativePath, "Movies/clip.mkv")
    }

    func testProbeAdvertisesRandomAccessChangeDetecting() async throws {
        let backend = FakeNFSBackend()
        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        let session = try await adapter.connect(for: makeKey())
        let probe = try await session.fileSystem.probe()
        XCTAssertEqual(probe.capabilities.byteRangeBehavior, .randomAccess)
        XCTAssertEqual(probe.capabilities.consistency, .changeDetecting)
        XCTAssertTrue(probe.capabilities.supportsList)
    }

    func testValidateSurfacesBackendError() async throws {
        let backend = FakeNFSBackend()
        backend.validateError = NFSError.mountFailed(.accessDenied)
        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        let session = try await adapter.connect(for: makeKey())
        do {
            try await session.fileSystem.validate()
            XCTFail("expected validation failure")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .permissionDenied)
        }
    }

    func testConnectFailureShutsDownBackendAndMapsError() async {
        let backend = FakeNFSBackend()
        backend.connectError = NFSError.mountFailed(.accessDenied)
        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        do {
            _ = try await adapter.connect(for: try makeKey())
            XCTFail("expected connect failure")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .permissionDenied)
            XCTAssertTrue(backend.didShutdown)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPathTraversalRejected() async throws {
        let backend = FakeNFSBackend()
        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        let session = try await adapter.connect(for: makeKey())
        do {
            _ = try await session.fileSystem.stat(relativePath: "../secret")
            XCTFail("expected traversal rejection")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .invalidInput(reason: "NFS path traversal"))
        }
    }

    func testOpenSourceValidatesRepresentationAndReads() async throws {
        let revision = CredentialRevision()
        let modifiedAt = Date(timeIntervalSince1970: 500)
        let bytes = Data((0..<16).map { UInt8($0) })
        let backend = FakeNFSBackend()
        backend.statEntry = NFSBackendEntry(
            name: "clip.mkv",
            kind: .file,
            size: Int64(bytes.count),
            modifiedAt: modifiedAt
        )
        backend.sourceBytes = bytes

        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        let session = try await adapter.connect(for: makeKey(revision: revision))

        let representation = try RemoteFileRepresentation(
            size: Int64(bytes.count),
            identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: modifiedAt),
            consistency: .changeDetecting
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: revision,
            relativePath: "clip.mkv",
            representation: representation
        )
        let lease = try await session.fileSystem.openSource(for: locator)
        let cursor = try XCTUnwrap(lease.makeCursor())
        let read = try await cursor.read(at: 0, length: bytes.count)
        XCTAssertEqual(read, bytes)
        cursor.close()
    }

    func testOpenSourceRejectsChangedModificationTime() async throws {
        let revision = CredentialRevision()
        let backend = FakeNFSBackend()
        backend.statEntry = NFSBackendEntry(
            name: "clip.mkv",
            kind: .file,
            size: 16,
            modifiedAt: Date(timeIntervalSince1970: 999)  // moved since scan
        )
        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        let session = try await adapter.connect(for: makeKey(revision: revision))

        let representation = try RemoteFileRepresentation(
            size: 16,
            identity: RemoteFileIdentity(
                kind: .modificationTime,
                modifiedAt: Date(timeIntervalSince1970: 500)
            ),
            consistency: .changeDetecting
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: revision,
            relativePath: "clip.mkv",
            representation: representation
        )
        do {
            _ = try await session.fileSystem.openSource(for: locator)
            XCTFail("expected sourceChanged")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .sourceChanged(reason: "NFS representation changed since scan"))
        }
    }

    func testOpenSourceRejectsForeignLocator() async throws {
        let backend = FakeNFSBackend()
        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        let session = try await adapter.connect(for: makeKey(revision: CredentialRevision()))
        let representation = try RemoteFileRepresentation(
            size: 0,
            identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: Date(timeIntervalSince1970: 1)),
            consistency: .changeDetecting
        )
        let locator = try NetworkFileLocator(
            accountID: "someone-else",
            sourceID: "source",
            credentialRevision: CredentialRevision(),
            relativePath: "clip.mkv",
            representation: representation
        )
        do {
            _ = try await session.fileSystem.openSource(for: locator)
            XCTFail("expected locator mismatch")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .invalidInput(reason: "locator session mismatch"))
        }
    }

    func testShutdownForwardsToBackend() async throws {
        let backend = FakeNFSBackend()
        let adapter = NFSMediaTransportAdapter(backendFactory: { backend })
        let session = try await adapter.connect(for: makeKey())
        await session.shutdown()
        XCTAssertTrue(backend.didShutdown)
    }

    func testErrorMappingCoversKeyCases() {
        XCTAssertEqual(mapNFSError(NFSError.status(.stale)), .sourceChanged(reason: "NFS file handle went stale"))
        XCTAssertEqual(mapNFSError(NFSError.status(.accessDenied)), .permissionDenied)
        XCTAssertEqual(mapNFSError(NFSError.timeout), .timeout)
        XCTAssertEqual(mapNFSError(NFSError.rpcDenied(authError: true)), .authentication(reason: "NFS RPC credentials rejected"))
        XCTAssertEqual(mapNFSError(NFSError.mountFailed(.perm)), .permissionDenied)
    }
}
