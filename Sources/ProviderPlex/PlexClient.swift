import Foundation
import CoreModels
import CoreNetworking

/// Low-level Plex Media Server REST client.
///
/// One instance is bound to a single server `baseURL` + `token`. It deals only
/// in DTOs; mapping to `CoreModels` happens in `PlexProvider`. Mirrors the role
/// of `JellyfinClient` for the Plex backend.
public struct PlexClient: Sendable {
    public let baseURL: URL
    private let deviceProfile: PlexDeviceProfile
    private let token: String
    private let http: HTTPClient

    public init(
        baseURL: URL,
        deviceProfile: PlexDeviceProfile,
        token: String,
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.baseURL = baseURL
        self.deviceProfile = deviceProfile
        self.token = token
        self.http = http
    }

    private var headers: [String: String] { deviceProfile.headers(token: token) }

    // MARK: Browsing

    /// `GET /library/sections` — top-level libraries.
    func sections() async throws -> [PlexDirectory] {
        let endpoint = Endpoint(path: "/library/sections", headers: headers)
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Directory ?? []
    }

    /// `GET /library/onDeck` — Continue Watching.
    func onDeck(limit: Int) async throws -> [PlexMetadata] {
        let endpoint = Endpoint(
            path: "/library/onDeck",
            queryItems: containerQuery(start: 0, size: limit),
            headers: headers
        )
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Metadata ?? []
    }

    /// `GET /library/recentlyAdded` — newest items across libraries.
    func recentlyAdded(limit: Int) async throws -> [PlexMetadata] {
        let endpoint = Endpoint(
            path: "/library/recentlyAdded",
            queryItems: containerQuery(start: 0, size: limit),
            headers: headers
        )
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Metadata ?? []
    }

    /// `GET /library/metadata/{ratingKey}` — full detail for one item.
    func metadata(ratingKey: String) async throws -> PlexMetadata {
        let endpoint = Endpoint(path: "/library/metadata/\(ratingKey)", headers: headers)
        let container = try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL).MediaContainer
        guard let item = container.Metadata?.first else { throw AppError.notFound }
        return item
    }

    /// `GET /library/metadata/{ratingKey}/children` — seasons of a show,
    /// episodes of a season, …
    func children(ratingKey: String) async throws -> [PlexMetadata] {
        let endpoint = Endpoint(path: "/library/metadata/\(ratingKey)/children", headers: headers)
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Metadata ?? []
    }

    /// `GET /library/sections/{id}/all` — one page of a library section, paged
    /// server-side with `X-Plex-Container-Start` / `X-Plex-Container-Size`.
    func sectionItems(
        sectionID: String,
        type: Int?,
        start: Int,
        size: Int
    ) async throws -> PlexMediaContainer {
        var query = containerQuery(start: start, size: size)
        if let type {
            query.append(URLQueryItem(name: "type", value: String(type)))
        }
        query.append(URLQueryItem(name: "sort", value: "titleSort"))
        let endpoint = Endpoint(path: "/library/sections/\(sectionID)/all", queryItems: query, headers: headers)
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL).MediaContainer
    }

    /// `GET /search?query=…` — global server search across libraries. Returns a
    /// flat `Metadata` list of matching movies/shows/episodes.
    func search(query: String, limit: Int) async throws -> [PlexMetadata] {
        var items = containerQuery(start: 0, size: limit)
        items.append(URLQueryItem(name: "query", value: query))
        let endpoint = Endpoint(path: "/search", queryItems: items, headers: headers)
        return try await http.decode(PlexMediaContainerResponse.self, from: endpoint, baseURL: baseURL)
            .MediaContainer.Metadata ?? []
    }

    // MARK: Playback

    /// `GET /:/timeline` — report progress so Plex keeps resume points in sync.
    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int?) async throws {
        var query = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        if let durationMs {
            query.append(URLQueryItem(name: "duration", value: String(durationMs)))
        }
        let endpoint = Endpoint(path: "/:/timeline", queryItems: query, headers: headers)
        _ = try await http.send(endpoint, baseURL: baseURL)
    }

    // MARK: URLs

    /// Builds an absolute, token-bearing stream URL for a part `key` (which is
    /// already a server-relative `/library/parts/…/file.…` path).
    func streamURL(forPartKey key: String) -> URL? {
        absoluteURL(serverPath: key, extraQuery: [URLQueryItem(name: "X-Plex-Token", value: token)])
    }

    /// Builds an absolute, token-bearing image URL for a server-relative art
    /// path (`thumb`/`art`), routed through Plex's photo transcoder so tvOS gets
    /// an appropriately sized image.
    func imageURL(path: String?, maxWidth: Int?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        guard let width = maxWidth else {
            return absoluteURL(serverPath: path, extraQuery: [URLQueryItem(name: "X-Plex-Token", value: token)])
        }
        let height = Int(Double(width) * 1.5)
        return absoluteURL(
            serverPath: "/photo/:/transcode",
            extraQuery: [
                URLQueryItem(name: "width", value: String(width)),
                URLQueryItem(name: "height", value: String(height)),
                URLQueryItem(name: "minSize", value: "1"),
                URLQueryItem(name: "url", value: path),
                URLQueryItem(name: "X-Plex-Token", value: token)
            ]
        )
    }

    // MARK: Helpers

    private func containerQuery(start: Int, size: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size))
        ]
    }

    private func absoluteURL(serverPath path: String, extraQuery: [URLQueryItem]) -> URL? {
        // An already-absolute path (rare) is returned as-is.
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        if let pathComponents = URLComponents(string: path) {
            components.path = basePath + pathComponents.path
            components.queryItems = (pathComponents.queryItems ?? []) + extraQuery
        } else {
            components.path = basePath + path
            components.queryItems = extraQuery
        }
        return components.url
    }
}
