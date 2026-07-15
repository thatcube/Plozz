import Foundation
import CoreModels
import CoreNetworking
import ProviderJellyfin

/// Signs a user in with a Jellyfin/Emby username + password and builds a
/// `UserSession`.
///
/// This is intentionally the *lower-priority* alternative to Quick Connect: it
/// exists for people who'd rather type credentials, and for servers that have
/// Quick Connect turned off entirely. The resulting `UserSession` is identical
/// to the one Quick Connect produces, so everything downstream is unchanged.
public struct PasswordSignInService: Sendable {
    private let server: MediaServer
    private let deviceID: String
    private let http: HTTPClient

    public init(
        server: MediaServer,
        deviceID: String,
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.server = server
        self.deviceID = deviceID
        self.http = http
    }

    private var client: JellyfinClient {
        JellyfinClient(
            baseURL: server.baseURL,
            deviceProfile: JellyfinDeviceProfile(deviceID: deviceID),
            providerKind: server.provider,
            http: http
        )
    }

    /// Authenticates against the server. Throws `.invalidCredentials` when the
    /// username/password is rejected, or any transport error otherwise.
    public func signIn(username: String, password: String) async throws -> UserSession {
        let auth = try await client.authenticate(username: username, password: password)
        let resolvedServer = MediaServer(
            id: auth.serverID ?? server.id,
            name: server.name,
            baseURL: server.baseURL,
            provider: server.provider,
            version: server.version
        )
        return UserSession(
            server: resolvedServer,
            userID: auth.userID,
            userName: auth.userName,
            avatarURL: client.userAvatarURL(userID: auth.userID, maxWidth: 120, token: auth.token),
            deviceID: deviceID,
            accessToken: auth.token
        )
    }
}
