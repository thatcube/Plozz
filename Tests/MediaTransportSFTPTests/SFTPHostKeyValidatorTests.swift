import Crypto
import Foundation
import MediaTransportCore
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

@testable import MediaTransportSFTP

/// Coverage of the security-critical pieces of the real NIOSSH backend that can
/// be exercised without a live server: the SSH host-key SHA-256 pin comparison
/// and the single-shot user-authentication offer.
final class SFTPHostKeyValidatorTests: XCTestCase {
    private func makeHostKey() -> (NIOSSHPublicKey, [UInt8]) {
        let privateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let publicKey = privateKey.publicKey
        let fingerprint = SFTPHostKeyValidator.sha256Fingerprint(of: publicKey)!
        return (publicKey, fingerprint)
    }

    func testFingerprintIsSHA256OfWireBlob() throws {
        let (publicKey, fingerprint) = makeHostKey()
        let openSSH = String(openSSHPublicKey: publicKey)
        let base64 = String(openSSH.split(separator: " ")[1])
        let blob = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(fingerprint, Array(SHA256.hash(data: blob)))
        XCTAssertEqual(fingerprint.count, 32)
    }

    func testPinnedMatchSucceedsAndRecordsFingerprint() throws {
        let (publicKey, fingerprint) = makeHostKey()
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let validator = SFTPHostKeyValidator(policy: .pinned(sha256: fingerprint))
        let promise = loop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: publicKey, validationCompletePromise: promise)

        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertEqual(validator.capturedFingerprint, fingerprint)
    }

    func testPinnedMismatchFailsClosedWithTrustError() {
        let (publicKey, _) = makeHostKey()
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let validator = SFTPHostKeyValidator(policy: .pinned(sha256: Array(repeating: 0, count: 32)))
        let promise = loop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: publicKey, validationCompletePromise: promise)

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssertEqual(error as? MediaTransportError, .trust(reason: "SFTP host key mismatch"))
        }
    }

    func testCaptureTrustOnFirstUseAcceptsAndRecords() {
        let (publicKey, fingerprint) = makeHostKey()
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }

        let validator = SFTPHostKeyValidator(policy: .captureTrustOnFirstUse)
        let promise = loop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: publicKey, validationCompletePromise: promise)

        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertEqual(validator.capturedFingerprint, fingerprint)
    }

    func testUserAuthOffersPasswordExactlyOnce() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = SFTPUserAuthenticationDelegate(
            credential: .password(username: "viewer", password: "secret")
        )

        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .password, nextChallengePromise: first)
        let offer = try XCTUnwrap(try first.futureResult.wait())
        XCTAssertEqual(offer.username, "viewer")
        guard case let .password(password) = offer.offer else {
            return XCTFail("expected a password offer")
        }
        XCTAssertEqual(password.password, "secret")

        // A second challenge (server rejected the first) yields no further offer,
        // so authentication fails cleanly instead of looping.
        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .password, nextChallengePromise: second)
        XCTAssertNil(try second.futureResult.wait())
    }

    func testUserAuthWithoutPasswordMethodOffersNothing() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = SFTPUserAuthenticationDelegate(
            credential: .password(username: "viewer", password: "secret")
        )

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: promise)
        XCTAssertNil(try promise.futureResult.wait())
    }

    func testUserAuthPrivateKeyIsNotYetSupported() {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = SFTPUserAuthenticationDelegate(
            credential: .privateKey(username: "viewer", privateKeyPEM: "unused")
        )

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: promise)
        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssertEqual(
                error as? MediaTransportError,
                .unsupportedCapability("SFTP private-key authentication")
            )
        }
    }
}
