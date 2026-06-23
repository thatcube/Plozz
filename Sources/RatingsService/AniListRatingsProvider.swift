import Foundation
import CoreModels
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keyless anime ratings from the **AniList** GraphQL API.
///
/// For anime, the rating that *matters* is the community score on AniList/MAL — not
/// IMDb or Rotten Tomatoes (which barely cover anime). AniList needs no API key for
/// public reads and is rate-limited per IP, so this scales to any number of users
/// with no shared quota or distributable key. Best-effort: returns `[]` on any
/// failure or for non-anime items.
///
/// Resolution prefers a stamped id (AniList, then MAL via `idMal`) and falls back
/// to a romaji/english title search.
public struct AniListRatingsProvider: ExternalRatingsProviding {
    private let endpoint: URL
    private let session: URLSession

    public init(
        endpoint: URL = URL(string: "https://graphql.anilist.co")!,
        session: URLSession = .plozzDefault
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    public func ratings(for item: MediaItem) async -> [ExternalRating] {
        guard let (variableKey, variableValue) = Self.lookup(for: item) else { return [] }

        let document = """
        query ($id: Int, $idMal: Int, $search: String) {
          Media(id: $id, idMal: $idMal, search: $search, type: ANIME) { averageScore }
        }
        """
        var variables: [String: Any] = [:]
        variables[variableKey] = variableValue
        let body: [String: Any] = ["query": document, "variables": variables]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data

        guard let (responseData, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(GraphQLResponse.self, from: responseData),
              let score = decoded.data?.Media?.averageScore, score > 0
        else { return [] }

        // AniList's weighted mean is on 0–100 and shown by AniList as a percentage.
        return [ExternalRating(source: .anilist, value: Double(score), scale: .percent)]
    }

    /// Whether this is anime and, if so, the best AniList lookup variable to use.
    static func lookup(for item: MediaItem) -> (String, Any)? {
        guard isAnime(item) else { return nil }
        for (key, value) in item.providerIDs {
            let lowered = key.lowercased()
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if lowered.contains("anilist"), let id = Int(trimmed) { return ("id", id) }
        }
        for (key, value) in item.providerIDs {
            let lowered = key.lowercased()
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if (lowered.contains("myanimelist") || lowered == "mal"), let id = Int(trimmed) {
                return ("idMal", id)
            }
        }
        let title = (item.kind == .episode || item.kind == .season)
            ? (item.parentTitle ?? item.title) : item.title
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ("search", trimmed)
    }

    /// Anime detection mirroring `MetadataKit`'s classifier (kept local so
    /// RatingsService stays a leaf module with no extra dependency).
    static func isAnime(_ item: MediaItem) -> Bool {
        let idKeys = ["anilist", "anidb", "myanimelist", "shoko", "kitsu"]
        for key in item.providerIDs.keys {
            let lowered = key.lowercased()
            if lowered == "mal" || idKeys.contains(where: { lowered.contains($0) }) { return true }
        }
        return (item.genres + item.tags).contains { $0.lowercased().contains("anime") }
    }

    private struct GraphQLResponse: Decodable {
        let data: DataField?
        struct DataField: Decodable { let Media: Media? }
        struct Media: Decodable { let averageScore: Int? }
    }
}

/// Runs several ratings providers and merges their results, later providers taking
/// precedence per source. Lets the app layer keyless anime scores (AniList) under
/// authoritative movie/TV ratings (OMDb) behind the one `ExternalRatingsProviding`
/// the detail screen consumes.
public struct CompositeRatingsProvider: ExternalRatingsProviding {
    private let providers: [any ExternalRatingsProviding]

    public init(_ providers: [any ExternalRatingsProviding]) {
        self.providers = providers
    }

    public func ratings(for item: MediaItem) async -> [ExternalRating] {
        var merged: [ExternalRating] = []
        for provider in providers {
            let next = await provider.ratings(for: item)
            merged = merged.mergedWithAuthoritative(next)
        }
        return merged
    }
}
