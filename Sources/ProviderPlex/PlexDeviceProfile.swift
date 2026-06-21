import Foundation

/// Stable identity Plozz presents to Plex.tv and Plex Media Servers.
///
/// `clientIdentifier` must be stable for the lifetime of an install so Plex can
/// recognise the same device across sessions (and so PIN-issued auth tokens stay
/// bound to it). It is the same per-install device id Plozz uses for Jellyfin
/// (see `FeatureAuth.AccountStore.deviceID`).
///
/// Every Plex request carries a small set of `X-Plex-*` headers identifying the
/// product/device, plus `Accept: application/json` so servers return JSON rather
/// than their default XML. When authenticated, `X-Plex-Token` carries the secret
/// token; it is sensitive and must be redacted before logging (see `PlozzLog`).
public struct PlexDeviceProfile: Sendable, Hashable {
    public var product: String
    public var version: String
    public var device: String
    public var platform: String
    public var platformVersion: String
    public var deviceName: String
    public var clientIdentifier: String

    public init(
        product: String = "Plozz",
        version: String = "1.0",
        device: String = "Apple TV",
        platform: String = "tvOS",
        platformVersion: String = "17.0",
        deviceName: String = "Plozz",
        clientIdentifier: String
    ) {
        self.product = product
        self.version = version
        self.device = device
        self.platform = platform
        self.platformVersion = platformVersion
        self.deviceName = deviceName
        self.clientIdentifier = clientIdentifier
    }

    /// The `X-Plex-*` headers (plus `Accept`) sent on every request. When a
    /// `token` is present it's added as `X-Plex-Token`.
    public func headers(token: String? = nil) -> [String: String] {
        var headers = [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Device": device,
            "X-Plex-Device-Name": deviceName,
            "X-Plex-Platform": platform,
            "X-Plex-Platform-Version": platformVersion
        ]
        if let token, !token.isEmpty {
            headers["X-Plex-Token"] = token
        }
        return headers
    }
}
