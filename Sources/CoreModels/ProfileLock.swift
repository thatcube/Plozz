import CryptoKit
import Foundation

/// An optional PIN gate on a profile.
///
/// **Gates entry, not exit.** This matches how the rest of the category behaves
/// and, more importantly, how the Plex Home PIN Plozz already speaks to behaves:
/// Plex's own documentation describes it as "parents may wish to put a PIN on
/// their account so that their children can't freely switch to the parent
/// account". Netflix's Profile Lock is the same shape — a PIN to *open* a
/// profile. So a child profile is left open and the grown-up profiles are
/// locked; there is nowhere for the child to escape *to*, which needs one
/// mechanism instead of two.
///
/// **The PIN is never stored.** Only a salted, iterated SHA-256 verifier is
/// persisted, so reading the profile JSON (or the synced CloudKit record) does
/// not hand over the PIN.
///
/// Note the honest limit of that: a 4-digit PIN has 10,000 possible values, so
/// anyone who can run the hash offline can recover it in well under a second no
/// matter how the verifier is derived. The iteration count raises the cost of a
/// casual attempt and the salt stops one precomputed table covering every
/// profile, but this is a *family speed bump*, not a security boundary — the
/// same guarantee Netflix, Plex and Screen Time offer. Anything that must be
/// genuinely secret (server tokens) stays in the Keychain and is never gated on
/// this.
public struct ProfileLock: Codable, Hashable, Sendable {
    /// Random per-lock salt, base64. Stops one rainbow table covering every
    /// profile in the household.
    public var salt: String
    /// Base64 of `iterations` rounds of SHA-256 over `salt || pin`.
    public var verifier: String
    /// Rounds used to derive `verifier`. Stored so the cost can be raised later
    /// without invalidating existing locks.
    public var iterations: Int
    /// Whether the user chose "use the same PIN as Plex" when setting this up.
    ///
    /// Purely advisory: it drives copy ("this is also your Plex PIN") and lets
    /// the unlock step forward the entered PIN to Plex's switch-user call so the
    /// person is asked once instead of twice. The local verifier is still the
    /// authority, which is what keeps the lock working offline, on a
    /// Jellyfin-only profile, and on tvOS where the Plex call may fail.
    public var matchesPlexPIN: Bool

    public init(salt: String, verifier: String, iterations: Int, matchesPlexPIN: Bool = false) {
        self.salt = salt
        self.verifier = verifier
        self.iterations = iterations
        self.matchesPlexPIN = matchesPlexPIN
    }

    /// Rounds used for newly created locks.
    ///
    /// Chosen to stay imperceptible on the oldest supported Apple TV (a few tens
    /// of milliseconds) while making a naive brute force meaningfully slower.
    public static let defaultIterations = 120_000

    /// The PIN length the UI collects. Four digits is the cross-vendor norm —
    /// Netflix ("Enter 4 numbers to create your Profile Lock PIN") and Apple's
    /// Screen Time passcode both use it.
    public static let pinLength = 4

    /// Whether `pin` is a well-formed PIN: exactly `pinLength` ASCII digits.
    ///
    /// Deliberately strict about digits rather than accepting any 4 characters,
    /// so the stored verifier can never depend on locale-specific numerals that
    /// a different keyboard would render unenterable.
    public static func isValidPIN(_ pin: String) -> Bool {
        pin.count == pinLength && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber)
    }

    /// Create a lock for `pin`, generating a fresh random salt.
    /// - Returns: `nil` when `pin` isn't a valid 4-digit PIN.
    public static func make(
        pin: String,
        matchesPlexPIN: Bool = false,
        iterations: Int = ProfileLock.defaultIterations
    ) -> ProfileLock? {
        guard isValidPIN(pin) else { return nil }
        var saltBytes = Data(count: 16)
        for i in saltBytes.indices { saltBytes[i] = UInt8.random(in: .min ... .max) }
        let salt = saltBytes.base64EncodedString()
        return ProfileLock(
            salt: salt,
            verifier: derive(pin: pin, salt: salt, iterations: iterations),
            iterations: iterations,
            matchesPlexPIN: matchesPlexPIN
        )
    }

    /// Whether `pin` opens this lock.
    ///
    /// Compared in constant time so a caller can't learn the verifier prefix by
    /// timing repeated attempts. (Barely matters for a 4-digit space, but it
    /// costs nothing and keeps the primitive honest if the length ever grows.)
    public func matches(pin: String) -> Bool {
        guard Self.isValidPIN(pin) else { return false }
        let candidate = Self.derive(pin: pin, salt: salt, iterations: iterations)
        return Self.constantTimeEquals(candidate, verifier)
    }

    /// `iterations` rounds of SHA-256 over the salt and PIN.
    static func derive(pin: String, salt: String, iterations: Int) -> String {
        // Seed with salt || pin, then re-hash the digest. Re-hashing a
        // fixed-width digest (rather than re-hashing the input each round) is
        // what makes the cost linear in `iterations`.
        var digest = SHA256.hash(data: Data((salt + pin).utf8))
        for _ in 1 ..< max(1, iterations) {
            digest = SHA256.hash(data: Data(digest))
        }
        return Data(digest).base64EncodedString()
    }

    /// Length-independent, early-exit-free string comparison.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// Field-level revision for a profile lock.
///
/// Profiles sync as one record. Without a revision on the lock itself, a device
/// changing the profile's name or avatar from an older snapshot can legitimately
/// win the whole-record conflict and replace a newly-created lock with `nil`.
/// That is especially bad for a security control: unrelated cosmetic edits must
/// never unlock a profile.
///
/// Counter handles ordinary sequential edits. Nonce deterministically breaks the
/// rare tie where two devices edit from the same counter before seeing each
/// other. A deletion gets a revision too, so "no lock" can be distinguished from
/// "this old record predates lock revisions."
public struct ProfileLockRevision: Codable, Hashable, Sendable, Comparable {
    public var counter: Int64
    public var nonce: String

    public init(counter: Int64, nonce: String) {
        self.counter = counter
        self.nonce = nonce
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.nonce < rhs.nonce
    }

    public static func next(after revision: Self?) -> Self {
        Self(
            counter: (revision?.counter ?? 0) + 1,
            nonce: UUID().uuidString
        )
    }

    /// Existing locks created before revisions shipped are still protected from
    /// a stale `nil` record immediately after upgrade.
    public static func legacy(for lock: ProfileLock) -> Self {
        Self(counter: 0, nonce: lock.verifier)
    }
}

/// Result of checking a proposed Profile Lock PIN against the protected Plex Home
/// user(s) the profile watches as.
public enum PlexPINValidationResult: Equatable, Sendable {
    case valid
    case invalid
    /// Plex could not be reached or the account credential was unavailable, so
    /// the answer is unknown rather than false.
    case unavailable
}
