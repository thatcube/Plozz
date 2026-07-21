import Foundation
import CryptoKit
import CoreModels

// MARK: - Sync pairing crypto (v1: NON-SECRET config only)
//
// Productizes the validated pairing primitive (CryptoKit HPKE, RFC 9180) into a
// reusable API. In v1 the ONLY thing that can travel through it is a
// `SyncConfigSnapshot` — which is non-secret by construction (token-free account
// descriptors + profiles). This is a deliberate type-level guardrail: no token or
// password type is accepted here, so v1 cannot accidentally ship a secret over the
// pairing channel. (Extending this to carry credentials is the separately-reviewed
// deferred item, and must not reuse this API without that review.)
//
// The payload is sealed to the target device's ephemeral public key and bound to a
// pairing context (ceremony id + expiry), so a captured blob can't be opened by a
// different device or replayed into another pairing.

/// The pairing ceremony context, conveyed out-of-band (QR / short code) and mixed
/// into the HPKE `info` so the seal is bound to this specific, time-limited pairing.
public struct SyncPairingContext: Codable, Hashable, Sendable {
    public var ceremonyID: String
    public var expiresAtEpoch: Int
    public var protocolVersion: Int
    /// Kind guard — v1 only ever seals non-secret config.
    public var kind: String

    public static let currentProtocolVersion = 1
    public static let configKind = "sync-config-v1"

    public init(
        ceremonyID: String = UUID().uuidString,
        ttlSeconds: Int = 120,
        now: Date = Date(),
        protocolVersion: Int = SyncPairingContext.currentProtocolVersion,
        kind: String = SyncPairingContext.configKind
    ) {
        self.ceremonyID = ceremonyID
        self.expiresAtEpoch = Int(now.timeIntervalSince1970) + ttlSeconds
        self.protocolVersion = protocolVersion
        self.kind = kind
    }

    public func isExpired(now: Date = Date()) -> Bool {
        Int(now.timeIntervalSince1970) > expiresAtEpoch
    }

    fileprivate func infoData() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }
}

/// An opaque sealed blob only the paired target device can open.
public struct SealedSyncPayload: Codable, Hashable, Sendable {
    public var encapsulatedKey: Data
    public var ciphertext: Data
    public var context: SyncPairingContext
    public init(encapsulatedKey: Data, ciphertext: Data, context: SyncPairingContext) {
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
        self.context = context
    }
}

public enum SyncPairingError: Error, Equatable {
    case expiredContext
    case kindMismatch
    case decryptionFailed
}

/// Ephemeral key material a device advertises during pairing.
public struct SyncPairingIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }
    public init() { self.privateKey = Curve25519.KeyAgreement.PrivateKey() }
    public init(privateKey: Curve25519.KeyAgreement.PrivateKey) { self.privateKey = privateKey }
}

public enum SyncPairingCrypto {
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static let aad = Data("plozz-sync-pairing-v1".utf8)

    /// Seal a NON-SECRET config snapshot to the target device's public key.
    public static func seal(
        _ snapshot: SyncConfigSnapshot,
        toPublicKey publicKeyData: Data,
        context: SyncPairingContext
    ) throws -> SealedSyncPayload {
        guard context.kind == SyncPairingContext.configKind else { throw SyncPairingError.kindMismatch }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData)
        let info = try context.infoData()
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info)
        let plaintext = try JSONEncoder().encode(snapshot)
        let ct = try sender.seal(plaintext, authenticating: aad)
        return SealedSyncPayload(encapsulatedKey: sender.encapsulatedKey, ciphertext: ct, context: context)
    }

    /// Open a sealed payload with this device's pairing identity. Rejects expired
    /// or wrong-kind contexts; decryption fails for any other device.
    public static func open(
        _ payload: SealedSyncPayload,
        with identity: SyncPairingIdentity,
        now: Date = Date()
    ) throws -> SyncConfigSnapshot {
        guard payload.context.kind == SyncPairingContext.configKind else { throw SyncPairingError.kindMismatch }
        guard !payload.context.isExpired(now: now) else { throw SyncPairingError.expiredContext }
        let info = try payload.context.infoData()
        do {
            var recipient = try HPKE.Recipient(
                privateKey: identity.privateKey, ciphersuite: suite,
                info: info, encapsulatedKey: payload.encapsulatedKey
            )
            let pt = try recipient.open(payload.ciphertext, authenticating: aad)
            return try JSONDecoder().decode(SyncConfigSnapshot.self, from: pt)
        } catch let e as SyncPairingError {
            throw e
        } catch {
            throw SyncPairingError.decryptionFailed
        }
    }
}
