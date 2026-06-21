import Foundation

/// A media server Plozz can connect to.
///
/// `id` is the backend-assigned server identity (Jellyfin's `Id` from
/// `/System/Info/Public`). It lets us recognise the same server across
/// discovery + manual entry and de-duplicate the picker list.
public struct MediaServer: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Normalised base URL, e.g. `https://jelly.example.com` (no trailing slash).
    public var baseURL: URL
    public var provider: ProviderKind
    public var version: String?

    public init(
        id: String,
        name: String,
        baseURL: URL,
        provider: ProviderKind,
        version: String? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.provider = provider
        self.version = version
    }
}
