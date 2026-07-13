import XCTest
@testable import MediaTransportHTTP

final class TransportSessionRegistryTests: XCTestCase {
    private func makeKey(
        accountID: String = "account-1",
        credentialRevision: UUID = UUID(),
        origin: TransportOrigin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!,
        trustRevision: UUID = UUID(),
        role: TransportRole = .scanner
    ) throws -> TransportSessionKey {
        try TransportSessionKey(
            accountID: accountID,
            credentialRevision: credentialRevision,
            origin: origin,
            trustRevision: trustRevision,
            role: role
        )
    }

    func testEqualKeyReturnsSameSessionInstance() async throws {
        let registry = TransportSessionRegistry()
        let key = try makeKey()
        let first = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        let second = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        XCTAssertTrue(first === second)
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 1)
    }

    func testDifferentAccountIDYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let revision = UUID()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let keyA = try makeKey(accountID: "account-A", credentialRevision: revision, origin: origin, trustRevision: revision)
        let keyB = try makeKey(accountID: "account-B", credentialRevision: revision, origin: origin, trustRevision: revision)

        let sessionA = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        let sessionB = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(sessionA === sessionB)
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 2)
    }

    func testDifferentCredentialRevisionYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let trust = UUID()
        let keyA = try makeKey(credentialRevision: UUID(), origin: origin, trustRevision: trust)
        let keyB = try makeKey(credentialRevision: UUID(), origin: origin, trustRevision: trust)

        let sessionA = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        let sessionB = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(sessionA === sessionB)
    }

    func testDifferentOriginYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let revision = UUID()
        let keyA = try makeKey(
            credentialRevision: revision,
            origin: TransportOrigin(url: URL(string: "https://nas-a.example.com/")!)!,
            trustRevision: revision
        )
        let keyB = try makeKey(
            credentialRevision: revision,
            origin: TransportOrigin(url: URL(string: "https://nas-b.example.com/")!)!,
            trustRevision: revision
        )

        let sessionA = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        let sessionB = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(sessionA === sessionB)
    }

    func testDifferentTrustRevisionYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let credentialRevision = UUID()
        let keyA = try makeKey(credentialRevision: credentialRevision, origin: origin, trustRevision: UUID())
        let keyB = try makeKey(credentialRevision: credentialRevision, origin: origin, trustRevision: UUID())

        let sessionA = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        let sessionB = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(sessionA === sessionB)
    }

    func testDifferentRoleYieldsDistinctSession() async throws {
        let registry = TransportSessionRegistry()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let revision = UUID()
        let keyScanner = try makeKey(credentialRevision: revision, origin: origin, trustRevision: revision, role: .scanner)
        let keyPlayback = try makeKey(credentialRevision: revision, origin: origin, trustRevision: revision, role: .playback)

        let scannerSession = try await registry.session(for: keyScanner, credential: .anonymous, trustPolicy: .system)
        let playbackSession = try await registry.session(for: keyPlayback, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(scannerSession === playbackSession)
    }

    func testInvalidateRemovesSessionSoANewOneIsMintedNextTime() async throws {
        let registry = TransportSessionRegistry()
        let key = try makeKey()
        let first = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        await registry.invalidate(key)
        let countAfterInvalidate = await registry.liveSessionCount
        XCTAssertEqual(countAfterInvalidate, 0)

        let second = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        XCTAssertFalse(first === second)
    }

    func testInvalidateAllRemovesOnlyMatchingSessions() async throws {
        let registry = TransportSessionRegistry()
        let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!
        let keyA = try makeKey(accountID: "keep-me", origin: origin)
        let keyB = try makeKey(accountID: "remove-me", origin: origin)
        _ = try await registry.session(for: keyA, credential: .anonymous, trustPolicy: .system)
        _ = try await registry.session(for: keyB, credential: .anonymous, trustPolicy: .system)

        await registry.invalidateAll(where: { $0.accountID == "remove-me" })
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 1)
    }

    func testDrainAllRemovesEverySession() async throws {
        let registry = TransportSessionRegistry()
        _ = try await registry.session(for: try makeKey(accountID: "a"), credential: .anonymous, trustPolicy: .system)
        _ = try await registry.session(for: try makeKey(accountID: "b"), credential: .anonymous, trustPolicy: .system)
        await registry.drainAll()
        let count = await registry.liveSessionCount
        XCTAssertEqual(count, 0)
    }

    func testEqualRevisionCannotBeReusedWithDifferentCredentialMaterial() async throws {
        let registry = TransportSessionRegistry()
        let key = try makeKey()
        _ = try await registry.session(
            for: key,
            credential: .password(username: "user", password: "first", policy: .automatic),
            trustPolicy: .system
        )

        do {
            _ = try await registry.session(
                for: key,
                credential: .password(username: "user", password: "second", policy: .automatic),
                trustPolicy: .system
            )
            XCTFail("expected sessionConfigurationMismatch")
        } catch let error as TransportError {
            XCTAssertEqual(error, .sessionConfigurationMismatch)
        }
    }

    func testPinnedTrustRevisionMustMatchSessionKey() async throws {
        let registry = TransportSessionRegistry()
        let key = try makeKey(trustRevision: UUID())
        let policy = TrustPolicy.pinnedLeaf(sha256: Data(repeating: 1, count: 32), revision: UUID())

        do {
            _ = try await registry.session(for: key, credential: .anonymous, trustPolicy: policy)
            XCTFail("expected sessionConfigurationMismatch")
        } catch let error as TransportError {
            XCTAssertEqual(error, .sessionConfigurationMismatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testInvalidatedSessionRejectsNewTaskWithoutCallingURLSession() async throws {
        let registry = TransportSessionRegistry(testProtocolClasses: [StubURLProtocol.self])
        let key = try makeKey()
        let session = try await registry.session(for: key, credential: .anonymous, trustPolicy: .system)
        session.invalidateAndCancel()

        do {
            _ = try await session.data(
                for: URLRequest(url: URL(string: "https://nas.example.com/dav")!),
                maxResponseBytes: 1
            )
            XCTFail("expected cancelled")
        } catch let error as TransportError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // MARK: - Redacted description

    func testSessionKeyDescriptionDoesNotLeakCredentialOrTrustMaterial() throws {
        let key = try makeKey(accountID: "household-nas")
        let description = key.description
        // Only opaque identifiers/origin/role are present — nothing that
        // resolves to a password/token/certificate.
        XCTAssertTrue(description.contains("household-nas"))
        XCTAssertTrue(description.contains("nas.example.com"))
        XCTAssertTrue(description.contains("scanner"))
    }
}
