import Foundation
import CoreModels

// MARK: - Pairing invite, short code + bidirectional link
//
// Security model for the device→device non-secret/credential handoff:
//   • The target (e.g. Apple TV) shows a QR AND a short human code. Both identify
//     the same one-time Bonjour service; the QR additionally carries the target's
//     ephemeral PUBLIC KEY out-of-band.
//   • Pairing runs over a single bidirectional connection: the target first sends
//     its invite (public key + ceremony), then the source seals the payload to that
//     key and sends it back.
//   • If the source scanned the QR, it VERIFIES the streamed public key equals the
//     QR's — so a man-in-the-middle on the LAN can't substitute its own key (QR
//     path stays end-to-end secure). A code-only source (no camera) trusts the
//     keyed LAN connection gated by the short code.
//
// `PairingLink` abstracts the byte transport (Bonjour/Network.framework in
// production, in-memory in tests) so the whole flow is unit-testable.

/// What the target's QR encodes. NON-SECRET: a public key is safe to show.
public struct SyncPairingInvite: Codable, Hashable, Sendable {
    public var serviceName: String
    public var publicKeyData: Data
    public var context: SyncPairingContext

    public init(serviceName: String, publicKeyData: Data, context: SyncPairingContext) {
        self.serviceName = serviceName
        self.publicKeyData = publicKeyData
        self.context = context
    }

    /// Compact, URL-safe string embedded in the QR. Uses an https **Universal
    /// Link** so scanning it with the system Camera opens Plozz straight into
    /// pairing when installed, or shows a download/finish-setup page when not.
    /// The payload rides in the URL **fragment** (`#…`) so it is never sent to
    /// the server. Legacy `plozz-pair://` strings are still accepted by `decode`.
    public func encoded() -> String {
        SyncPairingInvite.universalLinkPrefix + encodedPayload()
    }

    /// The base64url payload alone (no scheme/URL), used by `encoded()` and tests.
    public func encodedPayload() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The Universal Link prefix the QR uses. The payload is appended as a
    /// fragment so it stays entirely client-side.
    public static let universalLinkPrefix = "https://plozz.app/pair#"
    /// Legacy custom-scheme prefix, still decoded for backward compatibility.
    public static let legacyScheme = "plozz-pair://"

    public static func decode(_ string: String) -> SyncPairingInvite? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = extractPayload(trimmed) else { return nil }
        var b64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(SyncPairingInvite.self, from: data)
    }

    /// Pull the base64url payload out of any accepted form: the https universal
    /// link (payload in the fragment, or a `d=` query as a fallback), the legacy
    /// `plozz-pair://` scheme, or a bare payload string.
    private static func extractPayload(_ string: String) -> String? {
        if string.hasPrefix(legacyScheme) {
            return String(string.dropFirst(legacyScheme.count))
        }
        if let scheme = URL(string: string)?.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            if let comps = URLComponents(string: string) {
                if let frag = comps.fragment, !frag.isEmpty { return frag }
                if let d = comps.queryItems?.first(where: { $0.name == "d" })?.value,
                   !d.isEmpty { return d }
            }
            return nil
        }
        // Bare payload (no scheme) — accept as-is.
        if !string.contains("://") && !string.contains("/") { return string }
        return nil
    }
}

/// Short, human-typeable pairing code — kept short + easy (Plex-style). Uppercase
/// letters + digits minus ambiguous ones (no I/L/O/U/0/1). The raw uppercased form
/// doubles as the Bonjour service name so a typed code finds the same service.
public enum SyncPairingCode {
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTVWXYZ23456789")

    /// Generate a fresh N-character code (default 4, like Plex/TV link codes).
    public static func generate(length: Int = 4) -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// Normalize user input: uppercase, strip spaces/dashes, map look-alikes.
    public static func normalize(_ input: String) -> String {
        input.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .replacingOccurrences(of: "O", with: "0")
    }

    /// Group for display. A 4-char code shows as-is (no dash); longer codes group.
    public static func grouped(_ code: String, size: Int = 4) -> String {
        let chars = Array(code)
        guard chars.count > size else { return code }
        return stride(from: 0, to: chars.count, by: size)
            .map { String(chars[$0..<min($0 + size, chars.count)]) }
            .joined(separator: "-")
    }
}

// MARK: - Bidirectional link

/// A bidirectional, framed byte link between two paired devices.
public protocol PairingLink: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

/// In-memory bidirectional link pair for tests. `makePair()` returns two ends whose
/// sends are delivered to the other's receives.
public actor InMemoryPairingLink: PairingLink {
    private var inbox: [Data] = []
    private var waiters: [CheckedContinuation<Data, Never>] = []
    private var peer: InMemoryPairingLink?

    public init() {}

    public static func makePair() async -> (host: InMemoryPairingLink, guest: InMemoryPairingLink) {
        let a = InMemoryPairingLink(); let b = InMemoryPairingLink()
        await a.setPeer(b); await b.setPeer(a)
        return (a, b)
    }

    func setPeer(_ p: InMemoryPairingLink) { peer = p }
    fileprivate func deliver(_ data: Data) {
        if let w = waiters.first { waiters.removeFirst(); w.resume(returning: data) }
        else { inbox.append(data) }
    }

    public func send(_ data: Data) async throws { await peer?.deliver(data) }
    public func receive() async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
    public nonisolated func close() {}
}

// MARK: - High-level pairing session (transport-agnostic)

public enum SyncPairingSession {

    /// Target/host side (e.g. Apple TV): send our invite, then receive + open the
    /// sealed transfer bundle.
    public static func hostReceiveSetup(
        identity: SyncPairingIdentity,
        context: SyncPairingContext,
        serviceName: String,
        over link: PairingLink,
        now: Date = Date()
    ) async throws -> SyncTransferBundle {
        let invite = SyncPairingInvite(serviceName: serviceName, publicKeyData: identity.publicKeyData, context: context)
        try await link.send(try JSONEncoder().encode(invite))
        let sealedData = try await link.receive()
        let sealed = try JSONDecoder().decode(SealedSyncPayload.self, from: sealedData)
        return try SyncPairingCrypto.open(sealed, with: identity, now: now)
    }

    /// Source/guest side (e.g. phone): receive the target's invite, optionally
    /// verify it against a scanned QR (MITM protection), seal our bundle to it, send.
    /// - Parameter expectedPublicKey: the QR-scanned key to verify against, or nil
    ///   for a code-only pairing (no out-of-band key to check).
    public static func guestSendSetup(
        _ bundle: SyncTransferBundle,
        over link: PairingLink,
        expectedPublicKey: Data?,
        now: Date = Date()
    ) async throws {
        let inviteData = try await link.receive()
        let invite = try JSONDecoder().decode(SyncPairingInvite.self, from: inviteData)
        if let expectedPublicKey, expectedPublicKey != invite.publicKeyData {
            throw SyncPairingError.decryptionFailed
        }
        guard !invite.context.isExpired(now: now) else { throw SyncPairingError.expiredContext }
        let sealed = try SyncPairingCrypto.seal(bundle, toPublicKey: invite.publicKeyData, context: invite.context)
        try await link.send(try JSONEncoder().encode(sealed))
    }
}
