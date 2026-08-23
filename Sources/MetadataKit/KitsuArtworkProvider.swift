import Foundation

/// Keyless anime artwork fallback from the **Kitsu** API (`kitsu.io`, JSON:API).
///
/// No API key for public reads, per-IP throttled. Used when AniList misses (or has
/// no banner): Kitsu's `coverImage` is a wide hero candidate and `posterImage` is
/// vertical key art. Resolution is by title search (Kitsu ids aren't commonly
/// stamped onto Jellyfin items).
///
/// Because a search is the only way in, every hit is checked against
/// ``AnimeTitleMatch`` before it is used. `filter[text]` is a relevance query that
/// always returns *something*, so an unverified top hit is not an answer, it is a
/// guess — and taking it served *Dragon Goes House-Hunting*'s poster for House of
/// the Dragon. A miss now costs one fall-through to the next source in the chain.
public struct KitsuArtworkProvider: ArtworkProvider {
    public let id = "kitsu"
    private let base = "https://kitsu.io/api/edge/anime"
    /// Enough candidates that the right title can be picked out from behind a
    /// more "relevant" one, small enough to stay one cheap request.
    private static let candidateLimit = 5

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
              let url = URL(
                string: "\(base)?filter[text]=\(escaped)&page[limit]=\(Self.candidateLimit)"
              )
        else { return nil }
        let response = await MetadataHTTP.get(Response.self, url: url)
        return Self.bestMatch(
            for: query,
            among: response?.data.map(\.attributes) ?? []
        )
    }

    /// The first candidate that actually names the title asked for, or `nil`.
    ///
    /// Kitsu orders by its own relevance score, so position says nothing about
    /// identity — only the titles do. An exact agreement anywhere in the set beats
    /// a merely compatible one earlier in it, because relevance happily ranks
    /// "Bleach: Thousand-Year Blood War" above plain "Bleach".
    static func bestMatch(
        for query: MetadataQuery,
        among candidates: [Attributes]
    ) -> Attributes? {
        var compatible: Attributes?
        for candidate in candidates {
            switch AnimeTitleMatch.confidence(query, among: candidate.allTitles) {
            case .exact: return candidate
            case .compatible: compatible = compatible ?? candidate
            case nil: continue
            }
        }
        return compatible
    }

    private struct Response: Decodable {
        let data: [Resource]
        struct Resource: Decodable { let attributes: Attributes }
    }

    struct Attributes: Decodable {
        let posterImage: Image?
        let coverImage: Image?
        let canonicalTitle: String?
        /// Locale-keyed titles (`en`, `en_jp`, `ja_jp`, …). Values are nullable in
        /// Kitsu's payloads, so the dictionary has to admit `nil` or the whole
        /// record fails to decode and the provider silently answers nothing.
        let titles: [String: String?]?
        let abbreviatedTitles: [String]?

        /// Every name Kitsu lists this work under, for identity checking only.
        var allTitles: [String?] {  // l10n:content — provider-supplied media titles compared as lookup keys
            [canonicalTitle]
                + (titles?.values.map { $0 } ?? [])
                + (abbreviatedTitles?.map { $0 } ?? [])
        }

        struct Image: Decodable {
            let large: String?
            let original: String?
        }
    }
}
