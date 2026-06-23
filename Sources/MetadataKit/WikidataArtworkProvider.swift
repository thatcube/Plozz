import Foundation
import CoreModels

/// Keyless movie/TV artwork from **Wikidata** + **Wikimedia Commons**.
///
/// No API key, no shared quota — every device hits the public MediaWiki action
/// API from its own IP, so it scales to any number of users and is fully
/// open-source friendly. This is the general-content counterpart to the keyless
/// anime backbone (AniList/Kitsu) and the keyless TV stills (TVmaze).
///
/// Capabilities (movies, western TV, and unknown content):
///  - `logo`   → the work's clear-logo (`P154`), a genuine transparent title PNG.
///               Wikidata's standout keyless strength — especially for Plex,
///               which surfaces no logo of its own.
///  - `hero`   → the work's image (`P18`) **only when it is genuinely landscape**,
///               so a portrait poster is never stretched into the 16:9 hero.
///  - `poster` → the work's image (`P18`), which for films is usually the poster.
///
/// Resolution prefers a concrete external id (IMDb `P345`, then TMDb
/// `P4947`/`P4983`) for an exact match, falling back to a label search. Commons
/// serves the file at any requested width via `Special:FilePath`, so we always
/// pull the largest sensible size for the slot.
public struct WikidataArtworkProvider: ArtworkProvider {
    public let id = "wikidata"

    public init() {}

    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        switch query.contentType {
        case .movie, .tvShow, .unknown: break
        case .anime, .music: return nil // served by their specialized keyless chains
        }
        switch kind {
        case .thumbnail: return nil // Wikidata has no per-episode stills
        case .hero, .poster, .logo: break
        }

        guard let qid = await resolveQID(for: query) else { return nil }
        guard let claims = await fetchClaims(qid: qid) else { return nil }

        switch kind {
        case .logo:
            guard let file = Self.filename(in: claims, qid: qid, property: "P154") else { return nil }
            return Self.commonsFileURL(file, width: Self.width(for: .logo))
        case .poster:
            guard let file = Self.filename(in: claims, qid: qid, property: "P18") else { return nil }
            return Self.commonsFileURL(file, width: Self.width(for: .poster))
        case .hero:
            guard let file = Self.filename(in: claims, qid: qid, property: "P18"),
                  let size = await imageSize(of: file),
                  Self.isUsableHero(width: size.width, height: size.height)
            else { return nil }
            return Self.commonsFileURL(file, width: Self.width(for: .hero))
        case .thumbnail:
            return nil
        }
    }

    // MARK: - QID resolution

    private func resolveQID(for query: MetadataQuery) async -> String? {
        // 1) IMDb id is the most reliable cross-reference.
        if let imdb = query.providerIDs.providerID(.imdb) ?? query.providerIDs.providerID(.seriesImdb),
           !imdb.isEmpty,
           let qid = await searchQID(statement: "P345=\(imdb)") {
            return qid
        }
        // 2) TMDb id (movie P4947 / TV series P4983).
        if let tmdb = query.providerIDs.providerID(.tmdb) ?? query.providerIDs.providerID(.seriesTmdb),
           !tmdb.isEmpty {
            let property = query.isTV ? "P4983" : "P4947"
            if let qid = await searchQID(statement: "\(property)=\(tmdb)") { return qid }
        }
        // 3) Label search (least precise; only used when no id resolves).
        return await searchQIDByTitle(query.title)
    }

    /// Resolves a QID via a `haswbstatement:` CirrusSearch query (exact id match).
    private func searchQID(statement: String) async -> String? {
        guard let escaped = metadataEscaped("haswbstatement:\(statement)"),
              let url = URL(string: "https://www.wikidata.org/w/api.php?action=query&format=json&list=search&srlimit=1&srsearch=\(escaped)")
        else { return nil }
        let response = await MetadataHTTP.get(SearchResponse.self, url: url)
        return response?.query?.search?.first?.title
    }

    private func searchQIDByTitle(_ title: String) async -> String? {
        guard let escaped = metadataEscaped(title),
              let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbsearchentities&format=json&language=en&uselang=en&type=item&limit=1&search=\(escaped)")
        else { return nil }
        let response = await MetadataHTTP.get(WBSearchResponse.self, url: url)
        return response?.search?.first?.id
    }

    // MARK: - Claims + image size

    private func fetchClaims(qid: String) async -> ClaimsResponse? {
        guard let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities&format=json&props=claims&ids=\(qid)") else {
            return nil
        }
        return await MetadataHTTP.get(ClaimsResponse.self, url: url)
    }

    private func imageSize(of file: String) async -> (width: Int, height: Int)? {
        guard let escaped = metadataEscaped("File:\(file)"),
              let url = URL(string: "https://commons.wikimedia.org/w/api.php?action=query&format=json&prop=imageinfo&iiprop=size&titles=\(escaped)")
        else { return nil }
        guard let response = await MetadataHTTP.get(ImageInfoResponse.self, url: url),
              let info = response.query?.pages?.values.first?.imageinfo?.first,
              let w = info.width, let h = info.height
        else { return nil }
        return (w, h)
    }

    // MARK: - Pure helpers (unit-tested)

    /// The Commons-served URL for a file at a target width. `Special:FilePath`
    /// returns the original, or a downscaled thumbnail when `width` is smaller —
    /// so we always get the largest sensible size without upscaling.
    static func commonsFileURL(_ file: String, width: Int) -> URL? {
        let normalized = file.replacingOccurrences(of: " ", with: "_")
        guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .commonsPathAllowed) else {
            return nil
        }
        return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=\(width)")
    }

    /// A `P18`/`P154` image is only acceptable as a hero when it is landscape and
    /// reasonably large, so portrait posters never fill the wide hero.
    static func isUsableHero(width: Int, height: Int) -> Bool {
        guard height > 0 else { return false }
        return width > height && width >= 1200
    }

    /// The target CDN width for each artwork slot.
    static func width(for kind: ArtworkKind) -> Int {
        switch kind {
        case .hero: return 3840
        case .poster: return 1000
        case .logo: return 800
        case .thumbnail: return 1280
        }
    }

    /// Extracts the first Commons filename for `property` (e.g. `P18`) from a
    /// decoded claims response.
    static func filename(in claims: ClaimsResponse, qid: String, property: String) -> String? {
        guard let entity = claims.entities?[qid],
              let statements = entity.claims?[property] else { return nil }
        for statement in statements {
            if let value = statement.mainsnak?.datavalue?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - DTOs

    struct SearchResponse: Decodable {
        let query: Query?
        struct Query: Decodable { let search: [Hit]? }
        struct Hit: Decodable { let title: String? }
    }

    struct WBSearchResponse: Decodable {
        let search: [Hit]?
        struct Hit: Decodable { let id: String? }
    }

    struct ClaimsResponse: Decodable {
        let entities: [String: Entity]?
        struct Entity: Decodable {
            let claims: [String: [Statement]]?
        }
        struct Statement: Decodable {
            let mainsnak: Snak?
        }
        struct Snak: Decodable {
            let datavalue: DataValue?
        }
        /// Commons-filename claims carry a bare string `value`; other claim types
        /// carry an object, which we simply ignore (decode to `nil`).
        struct DataValue: Decodable {
            let stringValue: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                stringValue = try? container.decode(String.self, forKey: .value)
            }
            enum CodingKeys: String, CodingKey { case value }
        }
    }

    struct ImageInfoResponse: Decodable {
        let query: Query?
        struct Query: Decodable { let pages: [String: Page]? }
        struct Page: Decodable { let imageinfo: [Info]? }
        struct Info: Decodable {
            let width: Int?
            let height: Int?
        }
    }
}

private extension CharacterSet {
    /// Path-segment-safe set for a Commons filename (keeps it out of the query and
    /// preserves the readable characters Commons accepts).
    static let commonsPathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "_-.,()!'")
        return set
    }()
}
