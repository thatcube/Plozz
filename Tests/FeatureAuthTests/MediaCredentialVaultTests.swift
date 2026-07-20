import XCTest
import CoreModels
@testable import FeatureAuthCore

final class MediaCredentialVaultTests: XCTestCase {
    private let revision = CredentialRevision(
        rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )

    func testCodecRoundTripsEverySupportedAuthentication() throws {
        let keyID = try CredentialChildItemID(rawValue: "sftp-key.account.1")
        let pin = try SHA256Fingerprint(bytes: Data(repeating: 0xAB, count: 32))
        let envelopes = [
            try MediaShareCredentialEnvelope(
                transport: .smb,
                authentication: .anonymous
            ),
            try MediaShareCredentialEnvelope(
                transport: .smb,
                authentication: .password(username: "alice", password: "smb-secret")
            ),
            try MediaShareCredentialEnvelope(
                transport: .webDAV,
                authentication: .bearer(token: "bearer-secret"),
                trust: MediaShareTrustMaterial(tlsLeafCertificateSHA256: pin)
            ),
            try MediaShareCredentialEnvelope(
                transport: .sftp,
                authentication: .generatedKey(username: "alice", keyID: keyID),
                trust: MediaShareTrustMaterial(sshHostKeySHA256: pin)
            ),
            try MediaShareCredentialEnvelope(
                transport: .nfs,
                authentication: .noCredentials
            )
        ]

        for envelope in envelopes {
            let encoded = try MediaShareCredentialCodec.encode(envelope)
            XCTAssertTrue(encoded.hasPrefix(MediaShareCredentialCodec.prefix))
            XCTAssertEqual(
                try MediaShareCredentialCodec.decode(
                    encoded,
                    expectedTransport: envelope.transport
                ),
                envelope
            )
        }
    }

    func testLegacySMBValueIsAlwaysRawPasswordNotOpportunisticJSON() throws {
        let raw = #"{"transport":"webDAV","secret":"not-a-schema"}"#
        let envelope = try MediaShareCredentialCodec.decode(
            raw,
            expectedTransport: .smb,
            legacyUsername: "alice"
        )

        guard case .password(let username, let password) = envelope.authentication else {
            return XCTFail("Expected legacy SMB password")
        }
        XCTAssertEqual(username, "alice")
        XCTAssertEqual(password, raw)
    }

    func testLegacyGuestSMBBecomesAnonymous() throws {
        let envelope = try MediaShareCredentialCodec.decode(
            "",
            expectedTransport: .smb,
            legacyUsername: ""
        )
        XCTAssertEqual(envelope.authentication, .anonymous)
    }

    func testUnversionedNonSMBCredentialIsRejected() {
        XCTAssertThrowsError(
            try MediaShareCredentialCodec.decode(
                "password",
                expectedTransport: .webDAV,
                legacyUsername: "alice"
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaCredentialError,
                .unversionedCredentialNotSupported
            )
        }
    }

    func testTransportMismatchAndMalformedPayloadFailClosed() throws {
        let envelope = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .anonymous
        )
        let encoded = try MediaShareCredentialCodec.encode(envelope)

        XCTAssertThrowsError(
            try MediaShareCredentialCodec.decode(encoded, expectedTransport: .smb)
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .transportMismatch)
        }
        XCTAssertThrowsError(
            try MediaShareCredentialCodec.decode(
                MediaShareCredentialCodec.prefix + "not-base64",
                expectedTransport: .webDAV
            )
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .malformedEnvelope)
        }
    }

    func testUnsupportedVersionIsRejectedBeforeVersionSpecificSchema() {
        let futureEnvelope = Data(#"{"version":2}"#.utf8).base64EncodedString()

        XCTAssertThrowsError(
            try MediaShareCredentialCodec.decode(
                MediaShareCredentialCodec.prefix + futureEnvelope,
                expectedTransport: .webDAV
            )
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .unsupportedVersion)
        }
    }

    func testOversizedEncodedPayloadIsRejectedBeforeDecoding() {
        let oversized = String(
            repeating: "A",
            count: MediaShareCredentialCodec.maximumPayloadBytes * 2
        )

        XCTAssertThrowsError(
            try MediaShareCredentialCodec.decode(
                MediaShareCredentialCodec.prefix + oversized,
                expectedTransport: .webDAV
            )
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .payloadTooLarge)
        }
    }

    func testVersionedEnvelopeRequiresCanonicalSchema() throws {
        let envelope = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: .anonymous
        )
        let encoded = try MediaShareCredentialCodec.encode(envelope)
        let payload = String(encoded.dropFirst(MediaShareCredentialCodec.prefix.count))
        let data = try XCTUnwrap(Data(base64Encoded: payload))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["unexpected"] = true
        let nonCanonical = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try MediaShareCredentialCodec.decode(
                MediaShareCredentialCodec.prefix + nonCanonical.base64EncodedString(),
                expectedTransport: .webDAV
            )
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .malformedEnvelope)
        }
    }

    func testOversizedLegacySMBCredentialIsRejected() {
        XCTAssertThrowsError(
            try MediaShareCredentialCodec.decode(
                String(
                    repeating: "x",
                    count: MediaShareCredentialCodec.maximumPayloadBytes + 1
                ),
                expectedTransport: .smb,
                legacyUsername: "alice"
            )
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .payloadTooLarge)
        }
    }

    func testEnvelopeRejectsCredentialAndTrustMismatches() throws {
        XCTAssertThrowsError(
            try MediaShareCredentialEnvelope(
                transport: .nfs,
                authentication: .password(username: "alice", password: "secret")
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaCredentialError,
                .incompatibleAuthentication
            )
        }

        let pin = try SHA256Fingerprint(bytes: Data(repeating: 0xAB, count: 32))
        XCTAssertThrowsError(
            try MediaShareCredentialEnvelope(
                transport: .smb,
                authentication: .anonymous,
                trust: MediaShareTrustMaterial(tlsLeafCertificateSHA256: pin)
            )
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .incompatibleTrust)
        }

        XCTAssertThrowsError(
            try MediaShareCredentialEnvelope(
                transport: .sftp,
                authentication: .password(username: "alice", password: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .incompatibleTrust)
        }
    }

    func testGeneratedKeyEnvelopeStoresOnlyChildIdentifier() throws {
        let id = try CredentialChildItemID(rawValue: "key.account.revision")
        let envelope = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: id),
            trust: MediaShareTrustMaterial(
                sshHostKeySHA256: try SHA256Fingerprint(
                    bytes: Data(repeating: 0xAB, count: 32)
                )
            )
        )
        let encoded = try MediaShareCredentialCodec.encode(envelope)

        XCTAssertFalse(encoded.contains("PRIVATE KEY"))
        XCTAssertFalse(envelope.description.contains(id.rawValue))
        XCTAssertFalse(envelope.description.contains("alice"))
        XCTAssertFalse(String(reflecting: envelope).contains(id.rawValue))
        XCTAssertFalse(String(reflecting: envelope.authentication).contains("alice"))
    }

    func testFingerprintAndChildIdentifierValidateWhenDecoded() throws {
        let shortFingerprint = try JSONEncoder().encode(Data(repeating: 0, count: 31))
        XCTAssertThrowsError(
            try JSONDecoder().decode(SHA256Fingerprint.self, from: shortFingerprint)
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .invalidFingerprint)
        }

        let invalidID = try JSONEncoder().encode("-----BEGIN PRIVATE KEY-----")
        XCTAssertThrowsError(
            try JSONDecoder().decode(CredentialChildItemID.self, from: invalidID)
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .invalidIdentifier)
        }

        XCTAssertThrowsError(try CredentialChildItemID(rawValue: " key-id"))
        XCTAssertThrowsError(try CredentialChildItemID(rawValue: "key-id "))
    }

    func testUnpinnedTrustRevisionIsStableForLegacySMBReads() throws {
        let first = try MediaShareCredentialCodec.decode(
            "secret",
            expectedTransport: .smb,
            legacyUsername: "alice"
        )
        let second = try MediaShareCredentialCodec.decode(
            "secret",
            expectedTransport: .smb,
            legacyUsername: "alice"
        )

        XCTAssertEqual(first, second)
    }

    func testVaultEntriesAreRevisionScopedImmutableAndIdempotent() throws {
        let store = InMemorySecureStore()
        let vault = MediaCredentialVault(secureStore: store)
        let original = try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: .password(username: "alice", password: "first")
        )
        let replacement = try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: .password(username: "alice", password: "second")
        )

        try vault.store(original, accountID: "account", revision: revision)
        try vault.store(original, accountID: "account", revision: revision)
        XCTAssertEqual(
            try vault.credential(
                accountID: "account",
                revision: revision,
                expectedTransport: .smb
            ),
            original
        )
        XCTAssertThrowsError(
            try vault.store(replacement, accountID: "account", revision: revision)
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .revisionAlreadyExists)
        }
    }

    func testSeparateVaultInstancesCannotReplaceOneRevision() throws {
        let store = InMemorySecureStore()
        let firstVault = MediaCredentialVault(secureStore: store)
        let secondVault = MediaCredentialVault(secureStore: store)
        let original = try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: .password(username: "alice", password: "first")
        )
        let replacement = try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: .password(username: "alice", password: "second")
        )

        try firstVault.store(original, accountID: "account", revision: revision)
        XCTAssertThrowsError(
            try secondVault.store(replacement, accountID: "account", revision: revision)
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .revisionAlreadyExists)
        }
        XCTAssertEqual(
            try firstVault.credential(
                accountID: "account",
                revision: revision,
                expectedTransport: .smb
            ),
            original
        )
    }

    func testVaultIsolatesAccountsAndRevisions() throws {
        let vault = MediaCredentialVault(secureStore: InMemorySecureStore())
        let secondRevision = CredentialRevision(
            rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let first = try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: .password(username: "alice", password: "first")
        )
        let second = try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: .password(username: "alice", password: "second")
        )

        try vault.store(first, accountID: "account-a", revision: revision)
        try vault.store(second, accountID: "account-a", revision: secondRevision)
        try vault.store(second, accountID: "account-b", revision: revision)

        XCTAssertEqual(
            try vault.credential(
                accountID: "account-a",
                revision: revision,
                expectedTransport: .smb
            ),
            first
        )
        XCTAssertEqual(
            try vault.credential(
                accountID: "account-a",
                revision: secondRevision,
                expectedTransport: .smb
            ),
            second
        )
        XCTAssertEqual(
            try vault.credential(
                accountID: "account-b",
                revision: revision,
                expectedTransport: .smb
            ),
            second
        )
    }

    func testPrivateKeyChildItemsRemainOutsideEnvelopeAndAreImmutable() throws {
        let vault = MediaCredentialVault(secureStore: InMemorySecureStore())
        let id = try CredentialChildItemID(rawValue: "sftp-key.account.revision")

        try vault.storePrivateKey("-----BEGIN PRIVATE KEY-----\nfirst", id: id)
        try vault.storePrivateKey("-----BEGIN PRIVATE KEY-----\nfirst", id: id)
        XCTAssertEqual(
            try vault.privateKey(id: id),
            "-----BEGIN PRIVATE KEY-----\nfirst"
        )
        XCTAssertThrowsError(
            try vault.storePrivateKey("-----BEGIN PRIVATE KEY-----\nsecond", id: id)
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .childItemAlreadyExists)
        }

        try vault.removePrivateKey(id: id)
        XCTAssertThrowsError(try vault.privateKey(id: id))
        XCTAssertThrowsError(
            try vault.storePrivateKey("-----BEGIN PRIVATE KEY-----\nsecond", id: id)
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .childItemRetired)
        }
    }

    func testGeneratedKeyEnvelopeRequiresExistingChildItem() throws {
        let vault = MediaCredentialVault(secureStore: InMemorySecureStore())
        let id = try CredentialChildItemID(rawValue: "sftp-key.account.revision")
        let pin = try SHA256Fingerprint(bytes: Data(repeating: 0xAB, count: 32))
        let envelope = try MediaShareCredentialEnvelope(
            transport: .sftp,
            authentication: .generatedKey(username: "alice", keyID: id),
            trust: MediaShareTrustMaterial(sshHostKeySHA256: pin)
        )

        XCTAssertThrowsError(
            try vault.store(envelope, accountID: "account", revision: revision)
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .credentialNotFound)
        }

        try vault.storePrivateKey("private-key", id: id)
        try vault.store(envelope, accountID: "account", revision: revision)
        try vault.removePrivateKey(id: id)
        XCTAssertThrowsError(
            try vault.credential(
                accountID: "account",
                revision: revision,
                expectedTransport: .sftp
            )
        ) { error in
            XCTAssertEqual(error as? MediaCredentialError, .credentialNotFound)
        }
    }
}
