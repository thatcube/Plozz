import CoreModels
import Foundation
import MediaTransportCore
@testable import ProviderShare
import XCTest

/// Coverage for the representation identity `ShareProvider.networkFileLocator`
/// builds: a WebDAV `stat` carrying a strong ETag must produce a `.strongETag`
/// identity (so the byte source can `If-Match`-revalidate every read), while an
/// SMB-style entry (modification time, no ETag) falls back to
/// `.modificationTime`, and an entry with neither is rejected.
final class ShareProviderLocatorTests: XCTestCase {
    private func makeProvider(stat: RemoteFileEntry) -> ShareProvider {
        let fileSystem = LocatorFakeFileSystem(statEntry: stat)
        let session = LocatorFakeSession(fileSystem: fileSystem)
        let server = MediaServer(
            id: "share:https://nas.example.com/dav#anon",
            name: "DAV",
            baseURL: URL(string: "https://nas.example.com/dav")!,
            provider: .mediaShare
        )
        let userSession = UserSession(
            server: server,
            userID: "anon",
            userName: "",
            deviceID: "device",
            accessToken: ""
        )
        return ShareProvider(
            session: userSession,
            sessionFactory: { _ in session }
        )
    }

    func testStrongETagStatProducesStrongETagIdentity() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv",
            kind: .file,
            size: 4096,
            modifiedAt: Date(timeIntervalSince1970: 10),
            strongETag: "\"abc-123\""
        )
        let locator = try await makeProvider(stat: entry).networkFileLocator(for: "movie.mkv")
        XCTAssertEqual(locator.representation.identity.kind, .strongETag)
        XCTAssertEqual(locator.representation.identity.value, "\"abc-123\"")
        XCTAssertEqual(locator.representation.size, 4096)
    }

    func testModificationTimeStatProducesModificationTimeIdentity() async throws {
        let entry = try RemoteFileEntry(
            relativePath: "movie.mkv",
            kind: .file,
            size: 4096,
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let locator = try await makeProvider(stat: entry).networkFileLocator(for: "movie.mkv")
        XCTAssertEqual(locator.representation.identity.kind, .modificationTime)
    }

    func testStatWithNeitherIdentityIsRejected() async throws {
        let entry = try RemoteFileEntry(relativePath: "movie.mkv", kind: .file, size: 4096)
        do {
            _ = try await makeProvider(stat: entry).networkFileLocator(for: "movie.mkv")
            XCTFail("expected a protocolViolation for an entry with no stable identity")
        } catch let error as MediaTransportError {
            guard case .protocolViolation = error else {
                return XCTFail("expected protocolViolation, got \(error)")
            }
        }
    }
}

private final class LocatorFakeSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem

    init(fileSystem: any MediaTransportFileSystem) {
        // Force-try in a test helper: the endpoint inputs are valid constants.
        // swiftlint:disable:next force_try
        key = MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: CredentialRevision(),
            endpoint: try! MediaTransportEndpointIdentity(
                transportIdentifier: "https",
                host: "nas.example.com",
                rootPath: "/dav"
            ),
            trustRevision: UUID(),
            role: .metadata
        )
        self.fileSystem = fileSystem
    }

    func shutdown() async {}
}

private final class LocatorFakeFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    private let statEntry: RemoteFileEntry

    init(statEntry: RemoteFileEntry) {
        self.statEntry = statEntry
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

    func list(relativePath: String) async throws -> [RemoteFileEntry] { [] }

    func stat(relativePath: String) async throws -> RemoteFileEntry { statEntry }

    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data { Data() }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        throw MediaTransportError.unsupportedCapability("test")
    }
}
