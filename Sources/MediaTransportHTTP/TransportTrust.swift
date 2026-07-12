import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// TLS trust policy for one origin/trust-revision.
///
/// - `.system`: ordinary platform trust evaluation (chain validity + hostname
///   match). This is the default and covers every publicly-trusted server.
/// - `.pinnedLeaf`: an explicitly-accepted override for a self-signed or
///   otherwise replaced certificate. Pins the SHA-256 of the **exact leaf
///   certificate DER bytes** (not the SPKI/public key, not the whole chain)
///   for one `TransportOrigin` + `revision`. Accepting a *different* cert
///   later — even one that reuses the same key or is a renewal — requires a
///   new, explicit revision; it is never silently re-trusted. This is a
///   narrow "pin exactly this one artifact" mechanism, not a general
///   trust-all bypass: any leaf that doesn't produce this exact hash fails
///   closed with ``TransportError/trustPinMismatch``.
///
/// Bypassing chain/hostname validation for `.pinnedLeaf` is intentional (a
/// self-signed cert has no meaningful chain to validate), not a claim that
/// hostname mismatches are "safe" in general — `.system` still enforces
/// standard hostname validation, and choosing `.pinnedLeaf` is a deliberate,
/// per-origin, per-revision user decision made elsewhere (future setup UI),
/// not a default.
public enum TrustPolicy: Sendable, Equatable {
    case system
    case pinnedLeaf(sha256: Data, revision: UUID)
}

/// Computes the SHA-256 of a leaf certificate's DER encoding, and evaluates a
/// `TrustPolicy` against a captured leaf. Pure/data-only so pinning logic is
/// testable without a real TLS handshake.
public enum LeafCertificateTrust {
    /// SHA-256 over the exact DER bytes of the certificate — this is the
    /// value ``TrustPolicy/pinnedLeaf(sha256:revision:)`` stores and compares
    /// against, deliberately *not* a subject-public-key-info hash (SPKI
    /// pinning would keep trusting a re-issued cert with the same key; this
    /// module wants pinning to break, loudly, on any cert change so the user
    /// re-confirms).
    public static func sha256(ofLeafCertificateDER der: Data) -> Data {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: der)
        return Data(digest)
        #else
        return sha256Fallback(der)
        #endif
    }

    /// Decides whether `leafDER` satisfies `policy`. `.system` always
    /// defers to the platform trust evaluator (see
    /// ``SystemTrustEvaluator``); this function only handles the
    /// `.pinnedLeaf` exact-match case, which needs no platform APIs at all.
    public static func evaluatePinnedLeaf(
        _ leafDER: Data,
        against policy: TrustPolicy
    ) -> TransportError? {
        switch policy {
        case .system:
            return nil // handled by SystemTrustEvaluator, not here.
        case .pinnedLeaf(let pinnedSHA256, _):
            let actual = sha256(ofLeafCertificateDER: leafDER)
            return actual == pinnedSHA256 ? nil : .trustPinMismatch
        }
    }

    #if !canImport(CryptoKit)
    /// Minimal, dependency-free SHA-256 for platforms without CryptoKit
    /// (e.g. Linux toolchains that lack it). Never used on Apple platforms.
    private static func sha256Fallback(_ data: Data) -> Data {
        var h: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]
        var msg = [UInt8](data)
        let bitLength = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(msg[base]) << 24) | (UInt32(msg[base + 1]) << 16)
                    | (UInt32(msg[base + 2]) << 8) | UInt32(msg[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for value in h {
            out.append(UInt8((value >> 24) & 0xFF))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        }
        return Data(out)
    }
    #endif
}

#if canImport(Security)
/// Extracts the leaf certificate's DER bytes from a `SecTrust`, and runs the
/// platform's standard chain+hostname evaluation for `.system` policy.
/// Isolated behind `canImport(Security)` so the rest of the module (and its
/// pure-logic tests) compiles on non-Apple platforms too.
public enum SystemTrustEvaluator {
    /// The leaf (index 0) certificate's DER encoding, or `nil` if the trust
    /// object has no certificates (shouldn't happen for a real handshake).
    public static func leafCertificateDER(from trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        return SecCertificateCopyData(leaf) as Data
    }

    /// Standard system trust evaluation (chain validity + hostname), used
    /// for `TrustPolicy.system`. Returns `nil` on success.
    public static func evaluateSystemTrust(_ trust: SecTrust, host: String) -> TransportError? {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(trust, policy)
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(trust, &error)
        if isValid {
            return nil
        }
        let reason = error.map(String.init(describing:)) ?? "unknown trust evaluation failure"
        return .trustEvaluationFailed(reason: reason)
    }
}
#endif
