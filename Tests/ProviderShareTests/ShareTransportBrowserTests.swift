import CoreModels
import Foundation
import MediaTransportCore
@testable import ProviderShare
import XCTest

final class ShareTransportBrowserTests: XCTestCase {
    func testTransientFailureReplacesSessionAndRetriesOnce() async throws {
        let firstFileSystem = BrowserFakeFileSystem(
            listResults: [.failure(MediaTransportError.transport(code: 54))]
        )
        let secondEntry = try RemoteFileEntry(
            relativePath: "movie.mkv",
            kind: .file,
            size: 10
        )
        let secondFileSystem = BrowserFakeFileSystem(
            listResults: [.success([secondEntry])]
        )
        let firstSession = try BrowserFakeSession(fileSystem: firstFileSystem)
        let secondSession = try BrowserFakeSession(fileSystem: secondFileSystem)
        let factory = BrowserSessionFactory(sessions: [firstSession, secondSession])
        let browser = ShareTransportBrowser(
            role: .scanner,
            sessionFactory: { role in try factory.next(role: role) }
        )

        let entries = try await browser.listDirectory("")

        XCTAssertEqual(entries, [secondEntry])
        XCTAssertEqual(factory.roles, [.scanner, .scanner])
        XCTAssertEqual(firstSession.shutdownCount, 1)
        XCTAssertEqual(secondSession.shutdownCount, 0)

        await browser.close()
        XCTAssertEqual(secondSession.shutdownCount, 1)
    }

    func testAuthenticationFailureDoesNotReconnect() async throws {
        let fileSystem = BrowserFakeFileSystem(
            listResults: [.failure(MediaTransportError.authentication(reason: "rejected"))]
        )
        let session = try BrowserFakeSession(fileSystem: fileSystem)
        let factory = BrowserSessionFactory(sessions: [session])
        let browser = ShareTransportBrowser(
            role: .metadata,
            sessionFactory: { role in try factory.next(role: role) }
        )

        do {
            _ = try await browser.listDirectory("")
            XCTFail("Expected authentication failure")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .authentication(reason: "rejected"))
        }

        XCTAssertEqual(factory.roles, [.metadata])
        XCTAssertEqual(session.shutdownCount, 0)
    }
}

private final class BrowserSessionFactory: @unchecked Sendable {
    enum FactoryError: Error {
        case exhausted
    }

    private let lock = NSLock()
    private var sessions: [BrowserFakeSession]
    private var roleStorage: [MediaTransportRole] = []

    init(sessions: [BrowserFakeSession]) {
        self.sessions = sessions
    }

    var roles: [MediaTransportRole] {
        lock.withLock { roleStorage }
    }

    func next(role: MediaTransportRole) throws -> any MediaTransportSession {
        try lock.withLock {
            roleStorage.append(role)
            guard !sessions.isEmpty else { throw FactoryError.exhausted }
            return sessions.removeFirst()
        }
    }
}

private final class BrowserFakeSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    private let lock = NSLock()
    private var shutdownCountStorage = 0

    init(fileSystem: any MediaTransportFileSystem) throws {
        key = MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: CredentialRevision(),
            endpoint: try MediaTransportEndpointIdentity(
                transportIdentifier: "smb",
                host: "nas.local",
                rootPath: "/Media"
            ),
            trustRevision: UUID(),
            role: .scanner
        )
        self.fileSystem = fileSystem
    }

    var shutdownCount: Int {
        lock.withLock { shutdownCountStorage }
    }

    func shutdown() async {
        lock.withLock { shutdownCountStorage += 1 }
    }
}

private final class BrowserFakeFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var listResults: [Result<[RemoteFileEntry], Error>]

    init(listResults: [Result<[RemoteFileEntry], Error>]) {
        self.listResults = listResults
    }

    func validate() async throws {}

    func probe() async throws -> MediaTransportProbe {
        MediaTransportProbe(
            capabilities: try MediaTransportCapabilities(
                supportsList: true,
                supportsStat: true,
                supportsBoundedWholeFileRead: true,
                byteRangeBehavior: .randomAccess,
                maximumBoundedWholeFileReadBytes: 1_024,
                consistency: .changeDetecting
            )
        )
    }

    func list(relativePath: String) async throws -> [RemoteFileEntry] {
        let result = try lock.withLock {
            guard !listResults.isEmpty else {
                throw MediaTransportError.protocolViolation(reason: "missing fake result")
            }
            return listResults.removeFirst()
        }
        return try result.get()
    }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        try RemoteFileEntry(relativePath: relativePath, kind: .file, size: 0)
    }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        Data()
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        MediaTransportSourceLease(source: BrowserFakeByteSource())
    }
}

private final class BrowserFakeByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64 = 0

    func read(at offset: Int64, length: Int) async throws -> Data {
        Data()
    }

    func shutdown() async {}
}
