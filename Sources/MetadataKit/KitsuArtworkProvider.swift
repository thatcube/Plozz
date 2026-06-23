import Foundation

/// Keyless anime artwork fallback from the **Kitsu** API (`kitsu.io`, JSON:API).
///
/// No API key for public reads, per-IP throttled. Used when AniList misses (or has
/// no banner): Kitsu's `coverImage` is a wide hero candidate and `posterImage` is
/// vertical key art. Resolution is by title search (Kitsu ids aren't commonly
/// stamped onto Jellyfin items).
public struct KitsuArtworkProvider: ArtworkProvider {
    public let id = "kitsu"
    private let base = "https://kitsu.io/api/edge/anime"

    public init() {}

    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        guard query.contentType == .anime else { return nil }
        switch kind {
        case .hero, .poster: break
        case .thumbnail, .logo: return nil
        }
        guard let attributes = await fetchAttributes(for: query) else { return nil }
        switch kind {
        case .hero:
            let raw = attributes.coverImage?.original ?? attributes.coverImage?.large
            return raw.flatMap { URL(string: $0) }
        case .poster:
            let raw = attributes.posterImage?.original ?? attributes.posterImage?.large
            return raw.flatMap { URL(string: $0) }
        case .thumbnail, .logo:
            return nil
        }
    }

    private func fetchAttributes(for query: MetadataQuery) async -> Attributes? {
        guard let escaped = metadataEscaped(query.title),
              let url = URL(string: "\(base)?filter[text]=\(escaped)&page[limit]=1")
        else { return nil }
        let response = await MetadataHTTP.get(Response.self, url: url)
        return response?.data.first?.attributes
    }

    private struct Response: Decodable {
        let data: [Resource]
        struct Resource: Decodable { let attributes: Attributes }
    }

    struct Attributes: Decodable {
        let posterImage: Image?
        let coverImage: Image?
        struct Image: Decodable {
            let large: String?
            let original: String?
        }
    }
}
