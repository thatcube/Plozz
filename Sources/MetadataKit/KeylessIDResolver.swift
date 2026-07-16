import Foundation
import CoreModels

/// Resolves a title into strong **external IDs** (IMDb / TVDB / AniList / MAL)
/// with **no API key**, so items lacking server metadata — notably local
/// media-share files — can still merge across servers, pull external ratings, and
/// scrobble to Trakt/Simkl.
///
/// Sources (all keyless, per-IP rate-limited):
///  - **Anime** → AniList GraphQL (`id` = AniList id, `idMal` = MyAnimeList id).
///  - **TV** → TVmaze `singlesearch` (`externals.imdb`, `externals.thetvdb`).
///  - **Movies** → none here (no reliable keyless movie-id source); the bundled
///    TheTVDB tier and the optional user TMDb token fill movie ids in a later phase.
///
/// Returned keys use the canonical spellings the merge engine resolves
/// (`ProviderIDNamespace` — alias/case-insensitive): `Imdb`, `Tvdb`, `AniList`,
/// `Mal`. Values are best-effort; a miss simply returns fewer keys.
public struct KeylessIDResolver: Sendable {
    public init() {}

    /// Resolve external IDs for a title. `isAnime` routes to AniList; otherwise a
    /// TV title uses TVmaze. Movies (`isTV == false`, non-anime) return empty.
    public func externalIDs(title: String, year: Int?, isAnime: Bool, isTV: Bool) async -> [String: String] {
        await sourcedExternalIDs(
            title: title,
            year: year,
            isAnime: isAnime,
            isTV: isTV
        ).mapValues(\.value)
    }

    public func sourcedExternalIDs(
        title: String,
        year _: Int?,
        isAnime: Bool,
        isTV: Bool
    ) async -> [String: SourcedValue<String>] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        if isAnime {
            return await animeIDs(title: trimmed)
        }
        if isTV {
            return await tvIDs(title: trimmed)
        }
        return [:]
    }

    // MARK: - Anime (AniList)

    private func animeIDs(title: String) async -> [String: SourcedValue<String>] {
        let document = """
        query ($search: String) {
          Media(search: $search, type: ANIME) { id idMal }
        }
        """
        let body: [String: Any] = ["query": document, "variables": ["search": title]]
        guard let url = URL(string: "https://graphql.anilist.co"),
              let response = await MetadataHTTP.postJSON(AniListIDResponse.self, url: url, body: body),
              let media = response.data?.Media else { return [:] }
        let sourceURL = media.id.flatMap { URL(string: "https://anilist.co/anime/\($0)") }
        var ids: [String: SourcedValue<String>] = [:]
        if let anilist = media.id {
            ids["AniList"] = SourcedValue(
                value: String(anilist),
                source: .anilist,
                sourceURL: sourceURL
            )
        }
        if let mal = media.idMal {
            ids["Mal"] = SourcedValue(
                value: String(mal),
                source: .anilist,
                sourceURL: sourceURL
            )
        }
        return ids
    }

    private struct AniListIDResponse: Decodable {
        let data: DataField?
        struct DataField: Decodable { let Media: Media? }
        struct Media: Decodable { let id: Int?; let idMal: Int? }
    }

    // MARK: - TV (TVmaze)

    private func tvIDs(title: String) async -> [String: SourcedValue<String>] {
        guard let escaped = title.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
              let url = URL(string: "https://api.tvmaze.com/singlesearch/shows?q=\(escaped)"),
              let show = await MetadataHTTP.get(TVmazeShow.self, url: url) else { return [:] }
        let sourceURL = URL(string: "https://api.tvmaze.com/shows/\(show.id)")
        var ids: [String: SourcedValue<String>] = [:]
        if let imdb = show.externals?.imdb, !imdb.isEmpty {
            ids["Imdb"] = SourcedValue(value: imdb, source: .tvmaze, sourceURL: sourceURL)
        }
        if let tvdb = show.externals?.thetvdb {
            ids["Tvdb"] = SourcedValue(
                value: String(tvdb),
                source: .tvmaze,
                sourceURL: sourceURL
            )
        }
        return ids
    }

    private struct TVmazeShow: Decodable {
        let id: Int
        let externals: Externals?
        struct Externals: Decodable {
            let imdb: String?
            let thetvdb: Int?
        }
    }
}

private extension CharacterSet {
    /// URL-query-value-safe set (excludes `&`, `=`, `?`, `+`, space handled by encoding).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+")
        return set
    }()
}
