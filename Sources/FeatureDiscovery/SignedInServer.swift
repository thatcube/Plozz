import Foundation
import CoreModels

/// A server this device already has one or more signed-in accounts on.
///
/// The server picker surfaces these as first-class, one-tap targets so you can
/// add *another* user to a server you're already connected to (the common
/// family case: several users, one Jellyfin server) instead of re-typing an
/// address you obviously already know. This is **non-secret** metadata only —
/// derived from the persisted account list, never tokens.
public struct SignedInServer: Equatable, Sendable {
    public let server: MediaServer
    /// Names of the signed-in users on this server, in stable order.
    public let userNames: [String]

    public init(server: MediaServer, userNames: [String]) {
        self.server = server
        self.userNames = userNames
    }
}
