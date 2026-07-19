import Foundation

/// Keyless anime artwork from the **AniList** GraphQL API (`graphql.anilist.co`).
///
/// AniList needs no API key for public reads and is rate-limited *per IP* (~90
/// req/min), so it scales to any number of users: every device queries from its
/// own address with no shared quota to exhaust and no key to ban. This is the
/// backbone of Plozz's keyless anime experience.
///
/// Capabilities:
///  - `hero`   → `bannerImage` (a wide ~1900×400 banner, perfect for the hero)
///  - `poster` → `coverImage.extraLarge` (vertical key art)
///
/// Resolution prefers a concrete id (`AniList id`, then `idMal`) and only falls
/// back to a romaji/english title search, which is far less reliable for anime.
public struct AniListArtworkProvider: ArtworkProvider {
    public let id = "anilist"
    private let endpoint = URL(string: "https://graphql.anilist.co")!

    public init() {}

    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        guard query.contentType == .anime else { return nil }
        switch kind {
        case .hero, .poster:
            break
        case .thumbnail, .logo:
            return nil // AniList has no per-episode stills or clear logos.
        }
        guard let media = await fetchMedia(for: query) else { return nil }
        switch kind {
        case .hero:
            // Prefer the wide banner; AniList's cover is too tall for a hero.
            if let banner = media.bannerImage, let url = URL(string: banner) { return url }
            return nil
        case .poster:
            let raw = media.coverImage?.extraLarge ?? media.coverImage?.large
            return raw.flatMap { URL(string: $0) }
        case .thumbnail, .logo:
            return nil
        }
    }

    /// Fetches the best-matching AniList media for a query (id → idMal → search).
    public func fetchMedia(for query: MetadataQuery) async -> Media? {
        let document = """
        query ($id: Int, $idMal: Int, $search: String) {
          Media(id: $id, idMal: $idMal, search: $search, type: ANIME) {
            id
            idMal
            averageScore
            bannerImage
            coverImage { extraLarge large }
          }
        }
        """
        var variables: [String: Any] = [:]
        if let anilist = query.animeIDs.anilist {
            variables["id"] = anilist
        } else if let mal = query.animeIDs.mal {
            variables["idMal"] = mal
        } else if !query.title.isEmpty {
            variables["search"] = query.title
        } else {
            return nil
        }
        let body: [String: Any] = ["query": document, "variables": variables]
        let response = await MetadataHTTP.postJSON(GraphQLResponse.self, url: endpoint, body: body)
        return response?.data?.Media
    }

    // MARK: - DTOs

    struct GraphQLResponse: Decodable {
        let data: DataField?
        struct DataField: Decodable { let Media: Media? }
    }

    public struct Media: Decodable, Sendable {
        public let id: Int?
        public let idMal: Int?
        public let averageScore: Int?
        public let bannerImage: String?
        public let coverImage: CoverImage?

        public struct CoverImage: Decodable, Sendable {
            public let extraLarge: String?
            public let large: String?
        }
    }
}
