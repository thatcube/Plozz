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
/// sends are delivered to the other's receives. Closing an end unblocks BOTH ends'
/// pending receives with an error — mirroring a real socket close (the Bonjour
/// transport cancels its connection), so an aborted pairing frees the peer at once
/// instead of hanging until the phase timeout.
public actor InMemoryPairingLink: PairingLink {
    struct Closed: Error {}
    private var inbox: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var peer: InMemoryPairingLink?
    private var isClosed = false

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

    /// Fail all pending receives — called on this end's close and on the peer's.
    fileprivate func failWaiters() {
        isClosed = true
        let pending = waiters; waiters.removeAll()
        for w in pending { w.resume(throwing: Closed()) }
    }

    public func send(_ data: Data) async throws {
        if isClosed { throw Closed() }
        await peer?.deliver(data)
    }
    public func receive() async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if isClosed { throw Closed() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    public nonisolated func close() {
        Task { await self.closeNow() }
    }
    private func closeNow() async {
        failWaiters()
        await peer?.failWaiters()
    }
}

// MARK: - High-level pairing session (transport-agnostic)

/// Wire messages for the authenticated pairing handshake.
enum PairingHandshakeMode: String, Codable, Sendable { case qr, sas }

/// Guest's opening message. In SAS mode it carries the guest's nonce commitment,
/// sent BEFORE the host reveals its key — the binding that defeats a MITM.
struct PairingHello: Codable, Sendable {
    var mode: PairingHandshakeMode
    var commitment: Data?
}

/// Host's reply: its ephemeral public key, the ceremony context, and a fresh
/// per-connection nonce mixed into the SAS.
struct PairingHandshakeInvite: Codable, Sendable {
    var publicKeyData: Data
    var context: SyncPairingContext
    var hostNonce: Data
}

/// Guest reveals its nonce (SAS mode only).
struct PairingReveal: Codable, Sendable {
    var guestNonce: Data
}

public enum SyncPairingSession {

    /// Per-phase timeout so a stalled or malicious peer can never hang either side.
    static let phaseTimeout: Double = 60

    /// Target/host side (e.g. Apple TV): run the handshake, then receive + open the
    /// sealed transfer bundle. In SAS mode, `presentSAS` is invoked with the 6-digit
    /// code the moment it is known so the host UI can display it for comparison.
    public static func hostReceiveSetup(
        identity: SyncPairingIdentity,
        context: SyncPairingContext,
        serviceName: String,
        over link: PairingLink,
        presentSAS: @escaping @Sendable (String) -> Void = { _ in },
        now: Date = Date()
    ) async throws -> SyncTransferBundle {
        // 1. Await the guest's hello (with its commitment in SAS mode).
        let helloData = try await withPairingTimeout(seconds: phaseTimeout, onTimeout: { link.close() }) {
            try await link.receive()
        }
        let hello = try JSONDecoder().decode(PairingHello.self, from: helloData)

        // 2. Reveal our key + a fresh host nonce.
        let hostNonce = SyncPairingSAS.makeNonce()
        let invite = PairingHandshakeInvite(
            publicKeyData: identity.publicKeyData, context: context, hostNonce: hostNonce
        )
        try await link.send(try JSONEncoder().encode(invite))

        // 3. SAS mode: receive the guest's revealed nonce, verify the commitment,
        //    compute + surface the code for the human to compare.
        if hello.mode == .sas {
            guard let commitment = hello.commitment else { throw SyncPairingError.commitmentMismatch }
            let revealData = try await withPairingTimeout(seconds: phaseTimeout, onTimeout: { link.close() }) {
                try await link.receive()
            }
            let reveal = try JSONDecoder().decode(PairingReveal.self, from: revealData)
            guard SyncPairingSAS.verify(commitment: commitment, matchesGuestNonce: reveal.guestNonce) else {
                throw SyncPairingError.commitmentMismatch
            }
            let sas = SyncPairingSAS.code(
                hostPublicKey: identity.publicKeyData, hostNonce: hostNonce,
                guestNonce: reveal.guestNonce, ceremonyID: context.ceremonyID
            )
            presentSAS(sas)
        }

        // 4. Receive the sealed bundle (arrives only after the guest confirmed).
        let sealedData = try await withPairingTimeout(seconds: phaseTimeout, onTimeout: { link.close() }) {
            try await link.receive()
        }
        let sealed = try JSONDecoder().decode(SealedSyncPayload.self, from: sealedData)
        return try SyncPairingCrypto.open(sealed, with: identity, now: now)
    }

    /// Source/guest side (e.g. phone): run the handshake, then seal + send this
    /// device's bundle.
    /// - Parameters:
    ///   - expectedPublicKey: the QR-scanned key. When present the recipient is
    ///     already authenticated out-of-band, so no SAS is needed.
    ///   - confirmSAS: for the non-QR path, invoked with the 6-digit code; the
    ///     bundle is sent ONLY if it returns true (the user confirmed a match).
    public static func guestSendSetup(
        _ bundle: SyncTransferBundle,
        over link: PairingLink,
        expectedPublicKey: Data?,
        confirmSAS: @escaping @Sendable (String) async -> Bool = { _ in true },
        now: Date = Date()
    ) async throws {
        let mode: PairingHandshakeMode = expectedPublicKey == nil ? .sas : .qr

        // 1. Say hello. In SAS mode commit to our nonce BEFORE seeing the host key.
        let guestNonce = SyncPairingSAS.makeNonce()
        let hello = PairingHello(
            mode: mode,
            commitment: mode == .sas ? SyncPairingSAS.commitment(forGuestNonce: guestNonce) : nil
        )
        try await link.send(try JSONEncoder().encode(hello))

        // 2. Receive the host's key + nonce.
        let inviteData = try await withPairingTimeout(seconds: phaseTimeout, onTimeout: { link.close() }) {
            try await link.receive()
        }
        let invite = try JSONDecoder().decode(PairingHandshakeInvite.self, from: inviteData)
        guard !invite.context.isExpired(now: now) else { throw SyncPairingError.expiredContext }

        if let expectedPublicKey {
            // QR path: the key is authenticated out-of-band; no human comparison.
            guard expectedPublicKey == invite.publicKeyData else { throw SyncPairingError.decryptionFailed }
        } else {
            // SAS path: reveal our nonce, derive the code, require user confirmation.
            try await link.send(try JSONEncoder().encode(PairingReveal(guestNonce: guestNonce)))
            let sas = SyncPairingSAS.code(
                hostPublicKey: invite.publicKeyData, hostNonce: invite.hostNonce,
                guestNonce: guestNonce, ceremonyID: invite.context.ceremonyID
            )
            guard await confirmSAS(sas) else { throw SyncPairingError.notConfirmed }
        }

        // 3. Seal our bundle to the (now-authenticated) key and send it.
        let sealed = try SyncPairingCrypto.seal(bundle, toPublicKey: invite.publicKeyData, context: invite.context)
        try await link.send(try JSONEncoder().encode(sealed))
    }
}

/// Race an async operation against a timeout. If the timeout wins, `onTimeout` is
/// invoked (e.g. to close a link and unblock a pending receive) and
/// `BonjourPairingError.timedOut` is thrown.
func withPairingTimeout<T: Sendable>(
    seconds: Double,
    onTimeout: @escaping @Sendable () -> Void,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            onTimeout()
            throw BonjourPairingError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
