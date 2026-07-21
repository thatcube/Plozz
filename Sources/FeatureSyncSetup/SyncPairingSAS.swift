import Foundation
import CryptoKit

// MARK: - Short Authentication String (SAS) — MITM-resistant pairing auth
//
// The QR path authenticates the recipient out-of-band (the camera physically
// proves you're looking at the real device), so credentials can flow immediately.
// The no-camera paths (tap-to-pair, typed code, TV→phone) have no such proof, so
// a same-LAN active attacker could impersonate the target and receive the sealed
// credentials. To close that, non-QR credential transfer runs a commit/reveal
// numeric-comparison ceremony: both devices independently derive the SAME short
// code from the REAL key material, and the user confirms they match — exactly
// like Bluetooth/AirPods numeric comparison. A MITM who substitutes the key makes
// the two codes differ, so the human catches it.
//
// Security (why commit/reveal, not a naive hash): the guest commits to a secret
// nonce Ng BEFORE the host reveals its key + nonce, and reveals Ng LAST. Because
// each side is bound to its contribution before learning the other's, a MITM
// cannot grind a substituted key/nonce to make both codes match — the collision
// probability is 2^-(SAS bits) per ceremony (a one-shot online attempt that a
// mismatch immediately exposes).

public enum SyncPairingSAS {
    private static let commitDomain = Data("plozz-sas-commit-v1".utf8)
    private static let sasDomain = Data("plozz-sas-digest-v1".utf8)

    /// Fresh 32-byte nonce.
    public static func makeNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// The guest's commitment to its nonce, sent before the host reveals its key.
    public static func commitment(forGuestNonce nonce: Data) -> Data {
        var h = SHA256()
        h.update(data: commitDomain)
        h.update(data: nonce)
        return Data(h.finalize())
    }

    /// Verify a revealed guest nonce against its earlier commitment (constant-time).
    public static func verify(commitment: Data, matchesGuestNonce nonce: Data) -> Bool {
        let expected = Self.commitment(forGuestNonce: nonce)
        guard expected.count == commitment.count else { return false }
        return constantTimeEquals(expected, commitment)
    }

    /// The 6-digit code both devices derive from the real key material. Equal on
    /// both sides iff no key was substituted in between.
    public static func code(
        hostPublicKey: Data,
        hostNonce: Data,
        guestNonce: Data,
        ceremonyID: String
    ) -> String {
        var h = SHA256()
        h.update(data: sasDomain)
        h.update(data: lengthPrefixed(hostPublicKey))
        h.update(data: lengthPrefixed(hostNonce))
        h.update(data: lengthPrefixed(guestNonce))
        h.update(data: lengthPrefixed(Data(ceremonyID.utf8)))
        let digest = Array(h.finalize())
        // Take 20 bits → mod 1_000_000 → a stable 6-digit code (~1e-6 MITM chance).
        let value = (UInt32(digest[0]) << 16 | UInt32(digest[1]) << 8 | UInt32(digest[2])) % 1_000_000
        return String(format: "%06u", value)
    }

    /// A grouped display form, e.g. "482 193".
    public static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<mid]) \(code[mid...])"
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        var len = UInt32(data.count).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(data)
        return out
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
