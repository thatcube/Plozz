import Foundation
import CoreModels

// MARK: - Pairing invite + channel abstraction
//
// Security model for the phone→TV (or any device→device) non-secret handoff:
//   • The TV shows a QR / short code that encodes a `SyncPairingInvite` — its
//     ephemeral PUBLIC KEY + ceremony id + expiry. The public key travels via the
//     QR, NOT via the Bonjour advertisement, so a LAN bystander who cannot see the
//     TV's screen cannot seal a payload to it.
//   • Bonjour discovery only says "a TV is waiting" (convenience); the actual key
//     material is obtained by scanning. A payload is HPKE-sealed to the invite's
//     key and bound to the ceremony, so only the intended TV can open it.
//
// `PairingChannel` abstracts the byte transport (Bonjour/Network.framework in
// production, in-memory in tests) so the full export→seal→transfer→open→apply flow
// is unit-testable without real networking.

/// What the TV's QR / short code encodes. NON-SECRET: a public key is safe to show.
public struct SyncPairingInvite: Codable, Hashable, Sendable {
    public var serviceName: String
    public var publicKeyData: Data
    public var context: SyncPairingContext

    public init(serviceName: String, publicKeyData: Data, context: SyncPairingContext) {
        self.serviceName = serviceName
        self.publicKeyData = publicKeyData
        self.context = context
    }

    /// Compact, URL-safe string for embedding in a QR (`plozz-pair://<base64url>`).
    public func encoded() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "plozz-pair://" + b64
    }

    public static func decode(_ string: String) -> SyncPairingInvite? {
        guard string.hasPrefix("plozz-pair://") else { return nil }
        var b64 = String(string.dropFirst("plozz-pair://".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(SyncPairingInvite.self, from: data)
    }
}

/// Source side of a pairing byte channel.
public protocol PairingSending: Sendable {
    func send(_ payload: SealedSyncPayload) async throws
}

/// Target side of a pairing byte channel.
public protocol PairingReceiving: Sendable {
    func receive() async throws -> SealedSyncPayload
}

/// Convenience for transports that do both (e.g. the in-memory test channel).
public typealias PairingChannel = PairingSending & PairingReceiving

/// In-memory loopback channel for tests (source and target share one instance).
public actor InMemoryPairingChannel: PairingSending, PairingReceiving {
    private var buffer: [SealedSyncPayload] = []
    private var waiters: [CheckedContinuation<SealedSyncPayload, Never>] = []
    public init() {}

    public func send(_ payload: SealedSyncPayload) async throws {
        if let w = waiters.first { waiters.removeFirst(); w.resume(returning: payload) }
        else { buffer.append(payload) }
    }

    public func receive() async throws -> SealedSyncPayload {
        if !buffer.isEmpty { return buffer.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - High-level pairing session (transport-agnostic)

public enum SyncPairingSession {

    /// Source device (has the config): seal the snapshot to the invite and send.
    public static func sendConfig(
        _ snapshot: SyncConfigSnapshot,
        to invite: SyncPairingInvite,
        over channel: PairingSending,
        now: Date = Date()
    ) async throws {
        guard !invite.context.isExpired(now: now) else { throw SyncPairingError.expiredContext }
        let sealed = try SyncPairingCrypto.seal(snapshot, toPublicKey: invite.publicKeyData, context: invite.context)
        try await channel.send(sealed)
    }

    /// Target device (fresh): receive + open a config snapshot using its identity.
    public static func receiveConfig(
        with identity: SyncPairingIdentity,
        over channel: PairingReceiving,
        now: Date = Date()
    ) async throws -> SyncConfigSnapshot {
        let sealed = try await channel.receive()
        return try SyncPairingCrypto.open(sealed, with: identity, now: now)
    }
}
