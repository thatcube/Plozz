import Foundation

/// The household's optional Parental PIN — the key that turns a Kids Profile
/// from *curation* into *enforcement*.
///
/// **Why this is separate from ``ProfileLock``.** They answer different
/// questions, and conflating them is what made the first design unworkable:
///
/// - A Profile Lock says "this is *my* profile, don't open it". It is personal,
///   per-profile and optional, and everyone picks their own (or has none).
/// - A Parental PIN says "you're allowed to change what the child can reach". It
///   is one household secret, and nobody has to share a personal PIN to have it.
///
/// Requiring a Profile Lock on every grown-up profile would have meant setting a
/// PIN on three or four accounts — and forcing them all to match — just to get a
/// Kids Profile. This is one PIN, set once.
///
/// Every comparable product separates these two the same way. Netflix's Profile
/// Lock PIN opens a profile, but changing a maturity setting needs the *account
/// password*; Disney+ likewise. Apple's Restrictions passcode is its own secret,
/// unrelated to anyone's device passcode. Plozz has no account password to fall
/// back on, so the Parental PIN plays that role.
///
/// **Entirely optional.** A Kids Profile with no Parental PIN is still worth
/// having: a simpler page with the household settings hidden, which is all a
/// four-year-old needs. Nothing is gated until a PIN exists, which also means no
/// setting can ever be stranded behind a key nobody holds.
///
/// **The PIN is never stored** — only a salted, iterated verifier, derived by the
/// same routine ``ProfileLock`` uses. The honest limits described there apply
/// equally: four digits is a family speed bump, not a security boundary.
public struct ParentalPIN: Codable, Hashable, Sendable {
    /// Random per-PIN salt, base64.
    public var salt: String
    /// Base64 of `iterations` rounds of SHA-256 over `salt || pin`.
    public var verifier: String
    /// Rounds used to derive `verifier`, stored so the cost can be raised later
    /// without invalidating an existing PIN.
    public var iterations: Int

    public init(salt: String, verifier: String, iterations: Int) {
        self.salt = salt
        self.verifier = verifier
        self.iterations = iterations
    }

    /// Create a Parental PIN, generating a fresh random salt.
    /// - Returns: `nil` when `pin` isn't a valid 4-digit PIN.
    public static func make(
        pin: String,
        iterations: Int = ProfileLock.defaultIterations
    ) -> ParentalPIN? {
        guard ProfileLock.isValidPIN(pin) else { return nil }
        var saltBytes = Data(count: 16)
        for i in saltBytes.indices { saltBytes[i] = UInt8.random(in: .min ... .max) }
        let salt = saltBytes.base64EncodedString()
        return ParentalPIN(
            salt: salt,
            verifier: ProfileLock.derive(pin: pin, salt: salt, iterations: iterations),
            iterations: iterations
        )
    }

    /// Whether `pin` is the household's Parental PIN.
    public func matches(pin: String) -> Bool {
        guard ProfileLock.isValidPIN(pin) else { return false }
        let candidate = ProfileLock.derive(pin: pin, salt: salt, iterations: iterations)
        return ProfileLock.constantTimeEquals(candidate, verifier)
    }
}
