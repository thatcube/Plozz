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
/// An id lookup is authoritative and taken as-is; a **search** is a guess and is
/// accepted only when the media it returns actually names the title asked for
/// (``AnimeTitleMatch``). Without that check the search silently answers with the
/// nearest thing in the catalogue, which is a different work.
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
            title { romaji english native }
            synonyms
            nextAiringEpisode { airingAt episode }
          }
        }
        """
        var variables: [String: Any] = [:]
        // An id names one work; a title merely resembles one. Only the latter
        // needs its answer checked.
        var resolvedByTitleSearch = false
        if let anilist = query.animeIDs.anilist {
            variables["id"] = anilist
        } else if let mal = query.animeIDs.mal {
            variables["idMal"] = mal
        } else if !query.title.isEmpty {
            variables["search"] = query.title
            resolvedByTitleSearch = true
        } else {
            return nil
        }
        let body: [String: Any] = ["query": document, "variables": variables]
        let response = await MetadataHTTP.postJSON(GraphQLResponse.self, url: endpoint, body: body)
        guard let media = response?.data?.Media else { return nil }
        guard !resolvedByTitleSearch
                || AnimeTitleMatch.names(query, among: media.allTitles) else {
            return nil
        }
        return media
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
        public let title: Title?
        /// Alternate names AniList lists, which is often where a library's
        /// English spelling of a romaji-canonical show is found.
        public let synonyms: [String]?
        /// The next unaired episode (AniList numbers episodes absolutely within the
        /// media entry). Present only for currently-airing shows.
        public let nextAiringEpisode: AiringSchedule?

        public init(
            id: Int?,
            idMal: Int?,
            averageScore: Int?,
            bannerImage: String?,
            coverImage: CoverImage?,
            nextAiringEpisode: AiringSchedule? = nil,
            title: Title? = nil,
            synonyms: [String]? = nil
        ) {
            self.id = id
            self.idMal = idMal
            self.averageScore = averageScore
            self.bannerImage = bannerImage
            self.coverImage = coverImage
            self.nextAiringEpisode = nextAiringEpisode
            self.title = title
            self.synonyms = synonyms
        }

        /// Every name AniList lists this work under, for identity checking only.
        var allTitles: [String?] {  // l10n:content — provider-supplied media titles compared as lookup keys
            [title?.romaji, title?.english, title?.native]
                + (synonyms?.map { $0 } ?? [])
        }

        public struct CoverImage: Decodable, Sendable {
            public let extraLarge: String?
            public let large: String?

            public init(extraLarge: String?, large: String?) {
                self.extraLarge = extraLarge
                self.large = large
            }
        }

        public struct Title: Decodable, Sendable {
            public let romaji: String?
            public let english: String?
            public let native: String?

            public init(romaji: String?, english: String?, native: String?) {
                self.romaji = romaji
                self.english = english
                self.native = native
            }
        }

        /// AniList `AiringSchedule`: `airingAt` is a Unix timestamp (an exact
        /// instant), `episode` is the absolute episode number about to air.
        public struct AiringSchedule: Decodable, Sendable {
            public let airingAt: Int?
            public let episode: Int?

            public init(airingAt: Int?, episode: Int?) {
                self.airingAt = airingAt
                self.episode = episode
            }
        }
    }
}
