import Foundation

/// Stable identity Plozz presents to a Jellyfin server.
///
/// `deviceID` must be stable for the lifetime of an install so the server can
/// recognise the same device across sessions (and so Quick Connect/auth tokens
/// stay bound to it). Generate once and persist (see `FeatureAuth.SessionStore`).
public struct JellyfinDeviceProfile: Sendable, Hashable {
    public var client: String
    public var device: String
    public var deviceID: String
    public var version: String

    public init(
        client: String = "Plozz",
        device: String = "Apple TV",
        deviceID: String,
        version: String = "1.0"
    ) {
        self.client = client
        self.device = device
        self.deviceID = deviceID
        self.version = version
    }

    /// Builds the `Authorization: MediaBrowser …` header value Jellyfin expects.
    ///
    /// When `token` is present it's appended as `Token="…"`. The full value is
    /// sensitive and must be redacted before logging (see `PlozzLog`).
    public func authorizationHeaderValue(token: String? = nil) -> String {
        var parts = [
            "Client=\(quoted(client))",
            "Device=\(quoted(device))",
            "DeviceId=\(quoted(deviceID))",
            "Version=\(quoted(version))"
        ]
        if let token, !token.isEmpty {
            parts.append("Token=\(quoted(token))")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    private func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "") + "\""
    }
}
