import Foundation
import CoreModels

/// Keyless movie/TV artwork from **Wikipedia** (the English MediaWiki action API).
///
/// A second, independent Wikimedia path that catches works whose Wikidata claims
/// are sparse but which have a Wikipedia article with a lead image. No API key,
/// rate-limited per IP, fully open-source friendly.
///
/// Capabilities:
///  - `hero`   → the article's lead image (`pageimages` `original`) **only when it
///               is genuinely landscape**, so a portrait poster never fills the
///               wide hero.
///  - `poster` → the article's lead image, which for films is usually the poster.
///
/// Resolution uses a single search-generator query so one request yields the best
/// page *and* its original image.
public struct WikipediaArtworkProvider: ArtworkProvider {
    public let id = "wikipedia"

    public init() {}

    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        switch query.contentType {
        case .movie, .tvShow, .unknown: break
        case .anime, .music: return nil
        }
        switch kind {
        case .hero, .poster: break
        case .thumbnail, .logo: return nil // no episode stills or clear logos here
        }

        guard let url = Self.searchURL(title: query.title, year: query.year, isTV: query.isTV),
              let response = await MetadataHTTP.get(QueryResponse.self, url: url),
              let image = response.original
        else { return nil }

        switch kind {
        case .poster:
            return URL(string: image.source ?? "")
        case .hero:
            guard let source = image.source,
                  let w = image.width, let h = image.height,
                  WikidataArtworkProvider.isUsableHero(width: w, height: h)
            else { return nil }
            return URL(string: source)
        case .thumbnail, .logo:
            return nil
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Builds the search-generator + pageimages request. A type hint
    /// (`film` / `television series`) disambiguates same-named works.
    static func searchURL(title: String, year: Int?, isTV: Bool) -> URL? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var search = trimmed
        if isTV {
            search += " television series"
        } else if let year {
            search += " \(year) film"
        } else {
            search += " film"
        }
        guard let escaped = metadataEscaped(search) else { return nil }
        let string = "https://en.wikipedia.org/w/api.php?action=query&format=json"
            + "&prop=pageimages&piprop=original&generator=search&gsrnamespace=0&gsrlimit=1"
            + "&gsrsearch=\(escaped)"
        return URL(string: string)
    }

    // MARK: - DTOs

    struct QueryResponse: Decodable {
        let query: Query?
        struct Query: Decodable { let pages: [String: Page]? }
        struct Page: Decodable { let original: Image? }
        struct Image: Decodable {
            let source: String?
            let width: Int?
            let height: Int?
        }

        /// The first page's original image (the generator returns a single page).
        var original: Image? { query?.pages?.values.first?.original }
    }
}
