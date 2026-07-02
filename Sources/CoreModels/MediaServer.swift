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
    /// All known reachable base URLs for this server, most-preferred first
    /// (`baseURL` is `connectionURLs.first`). Plex servers advertise several
    /// connections (LAN, remote, relay); persisting the full set lets the client
    /// probe and self-heal onto whichever path is reachable at launch, instead of
    /// being pinned to one address that may have gone unreachable. `nil` for
    /// servers reached through a single fixed URL (e.g. a manually-entered host).
    public var connectionURLs: [URL]?

    public init(
        id: String,
        name: String,
        baseURL: URL,
        provider: ProviderKind,
        version: String? = nil,
        connectionURLs: [URL]? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.provider = provider
        self.version = version
        self.connectionURLs = connectionURLs
    }
}

public extension MediaServer {
    /// A stable de-duplication key for a server: the backend id when present,
    /// else `host:port`. Lets callers group/de-dupe the same box reached two
    /// ways (discovery, manual entry, an existing account) without duplicating
    /// the matching rules.
    var identityKey: String {
        if !id.isEmpty { return "id:\(id)" }
        let host = baseURL.host ?? baseURL.absoluteString
        let port = baseURL.port.map { ":\($0)" } ?? ""
        return "url:\(host)\(port)"
    }
}
