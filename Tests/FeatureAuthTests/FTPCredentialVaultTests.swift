import CoreModels
@testable import FeatureAuth
import Foundation
import XCTest

/// Coverage for FTP in the credential vault's (transport, auth) matrix, trust
/// rules, and codec round-trip.
final class FTPCredentialVaultTests: XCTestCase {
    func testFTPPasswordAndAnonymousAllowed() throws {
        XCTAssertNoThrow(try MediaShareCredentialEnvelope(
            transport: .ftp,
            authentication: .password(username: "alice", password: "secret")
        ))
        XCTAssertNoThrow(try MediaShareCredentialEnvelope(
            transport: .ftp,
            authentication: .anonymous
        ))
    }

    func testFTPRejectsBearerAndKeyAndNoCredentials() {
        XCTAssertThrowsError(try MediaShareCredentialEnvelope(
            transport: .ftp,
            authentication: .bearer(token: "t")
        ))
        XCTAssertThrowsError(try MediaShareCredentialEnvelope(
            transport: .ftp,
            authentication: .noCredentials
        ))
    }

    func testFTPSAllowsTLSLeafPin() throws {
        let pin = try SHA256Fingerprint(bytes: Data(repeating: 0xCD, count: 32))
        XCTAssertNoThrow(try MediaShareCredentialEnvelope(
            transport: .ftp,
            authentication: .password(username: "alice", password: "secret"),
            trust: MediaShareTrustMaterial(tlsLeafCertificateSHA256: pin)
        ))
    }

    func testFTPRejectsSSHHostKeyPin() throws {
        let pin = try SHA256Fingerprint(bytes: Data(repeating: 0xEF, count: 32))
        XCTAssertThrowsError(try MediaShareCredentialEnvelope(
            transport: .ftp,
            authentication: .anonymous,
            trust: MediaShareTrustMaterial(sshHostKeySHA256: pin)
        ))
    }

    func testFTPCodecRoundTrip() throws {
        let pin = try SHA256Fingerprint(bytes: Data(repeating: 0x11, count: 32))
        let envelopes = [
            try MediaShareCredentialEnvelope(transport: .ftp, authentication: .anonymous),
            try MediaShareCredentialEnvelope(
                transport: .ftp,
                authentication: .password(username: "alice", password: "secret"),
                trust: MediaShareTrustMaterial(tlsLeafCertificateSHA256: pin)
            ),
        ]
        for envelope in envelopes {
            let encoded = try MediaShareCredentialCodec.encode(envelope)
            XCTAssertEqual(
                try MediaShareCredentialCodec.decode(encoded, expectedTransport: .ftp),
                envelope
            )
        }
    }
}
