import Foundation

/// Result of a Quick Connect handshake, provider-agnostic.
public struct QuickConnectChallenge: Hashable, Sendable {
    /// Secret the client polls with (kept out of the UI/logs).
    public var secret: String
    /// Short human code the user types into their already-signed-in client/web UI.
    public var userCode: String
    public var isAuthenticated: Bool

    public init(secret: String, userCode: String, isAuthenticated: Bool) {
        self.secret = secret
        self.userCode = userCode
        self.isAuthenticated = isAuthenticated
    }
}

extension QuickConnectChallenge: CustomStringConvertible {
    /// Redacts the secret; the user code is safe to show.
    public var description: String {
        "QuickConnectChallenge(code: \(userCode), authenticated: \(isAuthenticated), secret: <redacted>)"
    }
}
