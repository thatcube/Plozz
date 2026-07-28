import CoreModels
import Foundation

/// Resolves titles related to a given one. Implemented per provider; the ranked
/// chain lives in ``RelatedTitlesResolver``.
public protocol RelatedTitlesProviding: Sendable {
    var id: MetadataSource { get }
    /// Whether this provider can answer at all (a missing key makes it inert).
    var isEnabled: Bool { get }
    func relatedTitles(for query: MetadataQuery, limit: Int) async -> [RelatedTitle]
}

// MARK: - AniList (keyless)

/// AniList relations + recommendations.
///
/// Leads the anime chain because it is the only source that models an anime's
/// *relations* — sequels, prequels, side stories — as first-class data. That's the
/// difference between "here are some shows a bit like this" and "your favourite
/// show has a sequel", which no recommendation feed will tell you.
///
/// Keyless, so it works in every build including third-party ones.
public struct AniListRelatedProvider: RelatedTitlesProviding {
    public let id: MetadataSource = .anilist
    public var isEnabled: Bool { true }

    private let fetch: @Sendable (String) async -> Data?

    public init(fetch: @escaping @Sendable (String) async -> Data? = AniListRelatedProvider.post) {
        self.fetch = fetch
    }

    private static let document = """
    query ($search: String, $id: Int) {
      Media(search: $search, id: $id, type: ANIME) {
        relations { edges { relationType node { id idMal type format \
    title { romaji english } startDate { year } coverImage { large } } } }
        recommendations(perPage: 12, sort: RATING_DESC) { nodes { mediaRecommendation \
    { id idMal type format title { romaji english } startDate { year } coverImage { large } } } }
      }
    }
    """

    public func relatedTitles(for query: MetadataQuery, limit: Int) async -> [RelatedTitle] {
        guard limit > 0, query.contentType == .anime else { return [] }
        var variables: [String: Any] = [:]
        if let anilist = query.animeIDs.anilist.flatMap(Int.init) {
            variables["id"] = anilist
        } else {
            variables["search"] = query.title
        }
        let body: [String: Any] = ["query": Self.document, "variables": variables]
        guard let payload = try? JSONSerialization.data(withJSONObject: body),
              let data = await fetch(String(decoding: payload, as: UTF8.self)),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let media = response.data?.Media
        else { return [] }

        var out: [RelatedTitle] = []
        for edge in media.relations?.edges ?? [] {
            guard let node = edge.node, node.type == "ANIME",
                  let relation = Self.relation(for: edge.relationType),
                  let mapped = Self.title(node, relation: relation)
            else { continue }
            out.append(mapped)
        }
        for node in media.recommendations?.nodes ?? [] {
            guard let recommended = node.mediaRecommendation, recommended.type == "ANIME",
                  let mapped = Self.title(recommended, relation: .recommendation)
            else { continue }
            out.append(mapped)
        }
        return Array(out.prefix(limit))
    }

    /// Maps AniList's relation vocabulary, keeping only the kinds a viewer would
    /// call "more of this".
    ///
    /// Adaptations and source material are deliberately excluded: the manga a show
    /// adapts isn't something anyone can watch, so it would be a dead row entry.
    /// `CHARACTER` and `OTHER` are too loose to justify a slot.
    static func relation(for raw: String?) -> RelatedTitle.Relation? {
        switch raw?.uppercased() {
        case "SEQUEL", "PREQUEL", "PARENT": return .continuation
        case "SIDE_STORY", "SPIN_OFF", "ALTERNATIVE": return .sideStory
        case "SUMMARY", "ADAPTATION", "SOURCE", "CHARACTER", "OTHER", "COMPILATION", "CONTAINS":
            return nil
        default: return nil
        }
    }

    private static func title(_ node: Node, relation: RelatedTitle.Relation) -> RelatedTitle? {
        let name = node.title?.english?.nonBlankValue ?? node.title?.romaji?.nonBlankValue
        guard let name else { return nil }
        var ids: [String: String] = [:]
        if let anilist = node.id { ids[ProviderIDNamespace.aniList.canonicalKey] = String(anilist) }
        if let mal = node.idMal { ids[ProviderIDNamespace.myAnimeList.canonicalKey] = String(mal) }
        return RelatedTitle(
            title: name,
            year: node.startDate?.year,
            // AniList models a film as its own entry; everything else is a series.
            kind: node.format?.uppercased() == "MOVIE" ? .movie : .series,
            relation: relation,
            providerIDs: ids,
            posterURL: node.coverImage?.large.flatMap(URL.init(string:)),
            source: .anilist
        )
    }

    public static func post(_ body: String) async -> Data? {
        guard let url = URL(string: "https://graphql.anilist.co") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try? await URLSession.shared.data(for: request).0
    }

    // MARK: DTOs

    private struct Response: Decodable { let data: Payload? }
    private struct Payload: Decodable { let Media: Media? }
    private struct Media: Decodable {
        let relations: Relations?
        let recommendations: Recommendations?
    }
    private struct Relations: Decodable { let edges: [Edge]? }
    private struct Edge: Decodable { let relationType: String?; let node: Node? }
    private struct Recommendations: Decodable { let nodes: [RecommendationNode]? }
    private struct RecommendationNode: Decodable { let mediaRecommendation: Node? }
    private struct Node: Decodable {
        let id: Int?
        let idMal: Int?
        let type: String?
        let format: String?
        let title: Title?
        let startDate: StartDate?
        let coverImage: CoverImage?
    }
    private struct Title: Decodable { let romaji: String?; let english: String? }
    private struct StartDate: Decodable { let year: Int? }
    private struct CoverImage: Decodable { let large: String? }
}

// MARK: - Trakt (bundled client id)

/// Trakt's community-curated `related` lists.
///
/// Leads the film/TV chain. Its client id is an app-level registration bundled in
/// every build, and `related` is public data needing no user sign-in, so this works
/// for everyone rather than only people who connected an account.
///
/// It also returns imdb + tmdb + tvdb ids for every entry, which is what lets a
/// result be matched to a library item by id rather than by name.
public struct TraktRelatedProvider: RelatedTitlesProviding {
    public let id: MetadataSource = .trakt
    private let clientID: String?
    private let fetch: @Sendable (URL, String) async -> Data?

    public var isEnabled: Bool { !(clientID ?? "").isEmpty }

    public init(
        clientID: String?,
        fetch: @escaping @Sendable (URL, String) async -> Data? = TraktRelatedProvider.get
    ) {
        self.clientID = clientID
        self.fetch = fetch
    }

    public func relatedTitles(for query: MetadataQuery, limit: Int) async -> [RelatedTitle] {
        guard isEnabled, limit > 0, let clientID else { return [] }
        // Trakt accepts a trakt slug/id or an imdb id in the same path position, so
        // an imdb id resolves exactly with no lookup step.
        guard let identifier = Self.identifier(for: query) else { return [] }
        let kindPath = query.isTV ? "shows" : "movies"
        guard let url = URL(
            string: "https://api.trakt.tv/\(kindPath)/\(identifier)/related?limit=\(limit)&extended=full"
        ) else { return [] }
        guard let data = await fetch(url, clientID),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }

        return entries.compactMap { entry -> RelatedTitle? in
            guard let name = entry.title?.nonBlankValue else { return nil }
            var ids: [String: String] = [:]
            if let tmdb = entry.ids?.tmdb { ids[ProviderIDNamespace.tmdb.canonicalKey] = String(tmdb) }
            if let imdb = entry.ids?.imdb?.nonBlankValue { ids[ProviderIDNamespace.imdb.canonicalKey] = imdb }
            if let tvdb = entry.ids?.tvdb { ids[ProviderIDNamespace.tvdb.canonicalKey] = String(tvdb) }
            guard !ids.isEmpty else { return nil }
            return RelatedTitle(
                title: name,
                year: entry.year,
                kind: query.isTV ? .series : .movie,
                relation: .recommendation,
                providerIDs: ids,
                posterURL: nil,
                source: .trakt
            )
        }
    }

    /// The path identifier Trakt will accept: an IMDb id, else a slug built from
    /// the title. Trakt resolves `tt…` directly, which avoids a search round-trip
    /// and can't mis-match.
    static func identifier(for query: MetadataQuery) -> String? {
        if let imdb = query.providerIDs.providerID(.imdb)?.nonBlankValue { return imdb }
        let slug = query.title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, character in
                if character == "-", partial.hasSuffix("-") { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }

    public static func get(_ url: URL, clientID: String) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        return try? await URLSession.shared.data(for: request).0
    }

    private struct Entry: Decodable {
        let title: String?
        let year: Int?
        let ids: IDs?
        struct IDs: Decodable {
            let tmdb: Int?
            let imdb: String?
            let tvdb: Int?
        }
    }
}

private extension String {
    var nonBlankValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
