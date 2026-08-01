import CoreModels
import Foundation

/// TMDb-backed artwork (backdrops, posters, logos, per-episode stills) reached via
/// the optional, maintainer-controlled ``TMDbAccess`` (proxy or local token).
///
/// TMDb is the gold standard for western movie/TV heroes, clear logos and episode
/// stills, but its terms forbid distributing a key in an open-source client. So
/// this provider is *only* enabled when a self-hostable caching proxy or a local
/// token is configured (never in the public build). The JSON metadata calls go
/// through `access`; the image *bytes* always come straight from TMDb's keyless
/// CDN (`image.tmdb.org`), keeping any proxy tiny and the byte path uncapped.
public struct TMDbMetadataProvider: ArtworkProvider {
    public let id = "tmdb"
    private let access: TMDbAccess

    /// API host: the proxy base (which forwards to TMDb, injecting the key) or
    /// TMDb directly when a local token is configured.
    private var apiBase: String {
        switch access {
        case .proxy(let url): return url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
        case .directToken, .userToken, .disabled: return "https://api.themoviedb.org"
        }
    }

    private let imageBase = "https://image.tmdb.org/t/p"

    /// Auth header for the JSON API: a v4 bearer in direct-token / user BYOK mode;
    /// none in proxy mode (the proxy injects the key server-side).
    private var authHeaders: [String: String] {
        switch access {
        case .directToken(let token), .userToken(let token): return ["Authorization": "Bearer \(token)"]
        case .proxy, .disabled: return [:]
        }
    }

    public init(access: TMDbAccess) {
        self.access = access
    }

    public var isEnabled: Bool { access.isEnabled }

    /// The work's original spoken language (ISO-639-1), when TMDb knows it.
    ///
    /// This is not a cosmetic metadata lookup. Playback's "Original" audio
    /// preference needs a real language: deferring to the container default is
    /// only a proxy, and real files can carry contradictory defaults. One
    /// Futurama episode reported both Portuguese and English as default; with no
    /// language requested, the demuxer picked the first one (Portuguese).
    ///
    /// A stamped TMDb id takes the exact details endpoint. Without one, the
    /// normal title/year matcher supplies the search result's `original_language`.
    public func originalLanguage(for query: MetadataQuery) async -> String? {
        guard access.isEnabled, query.contentType != .music else { return nil }
        if let id = stampedID(for: query),
           let url = url("/3/\(query.isTV ? "tv" : "movie")/\(id)"),
           let details = await MetadataHTTP.get(
               OriginalLanguageResponse.self,
               url: url,
               headers: authHeaders
           ) {
            return Self.normalizedLanguage(details.original_language)
        }
        return Self.normalizedLanguage(
            await search(query)?.original_language
        )
    }

    /// Regional release events and current watch offers for an external-title
    /// detail page. Best-effort and empty when TMDb is unavailable.
    public func externalAvailability(
        for query: MetadataQuery,
        regionCode: String
    ) async -> ExternalTitleAvailability {
        let region = regionCode.uppercased()
        guard access.isEnabled,
              query.contentType != .music,
              let id = await resolveID(for: query) else {
            return ExternalTitleAvailability(regionCode: region)
        }

        async let offers = watchOffers(
            id: id,
            isTV: query.isTV,
            regionCode: region
        )
        if query.isTV {
            let resolvedOffers = await offers
            return ExternalTitleAvailability(
                regionCode: region,
                watchOffers: resolvedOffers.offers,
                watchProvidersURL: resolvedOffers.link
            )
        }

        async let releaseDates = movieReleaseDates(id: id, regionCode: region)
        let (events, resolvedOffers) = await (releaseDates, offers)
        return ExternalTitleAvailability(
            regionCode: region,
            releaseEvents: events,
            watchOffers: resolvedOffers.offers,
            watchProvidersURL: resolvedOffers.link
        )
    }

    /// Ordered wide-backdrop URLs (best first), up to `limit`. Retaining a *set*
    /// (not just the single best) lets one response serve both the home hero and a
    /// distinct detail backdrop without a second search.
    public func backdropURLs(for query: MetadataQuery, limit: Int = 4) async -> [URL] {
        guard access.isEnabled, query.contentType != .music,
              let id = await resolveID(for: query) else { return [] }
        let images = await images(forID: id, isTV: query.isTV)
        return Self.rankedImagePaths(images?.backdrops, preferNeutral: true, limit: limit)
            .compactMap { URL(string: "\(imageBase)/original\($0)") }
    }

    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        guard access.isEnabled, query.contentType != .music else { return nil }
        switch kind {
        case .hero:
            guard let path = await backdropPath(for: query) else { return nil }
            return URL(string: "\(imageBase)/original\(path)")
        case .poster:
            guard let path = await posterPath(for: query) else { return nil }
            return URL(string: "\(imageBase)/w500\(path)")
        case .logo:
            guard let path = await logoPath(for: query) else { return nil }
            return URL(string: "\(imageBase)/w500\(path)")
        case .thumbnail:
            guard let season = query.seasonNumber, let episode = query.episodeNumber,
                  let seriesID = await resolveID(for: query, forceTV: true),
                  let path = await stillPath(seriesID: seriesID, season: season, episode: episode)
            else { return nil }
            return URL(string: "\(imageBase)/w1280\(path)")
        }
    }

    // MARK: - Lookups

    private func backdropPath(for query: MetadataQuery) async -> String? {
        guard let id = await resolveID(for: query) else { return nil }
        let images = await images(forID: id, isTV: query.isTV)
        return Self.bestImagePath(images?.backdrops, preferNeutral: true)
    }

    private func logoPath(for query: MetadataQuery) async -> String? {
        guard let id = await resolveID(for: query) else { return nil }
        let images = await images(forID: id, isTV: query.isTV)
        return Self.bestLogoPath(images?.logos)
    }

    private func posterPath(for query: MetadataQuery) async -> String? {
        // The search result already carries a poster, so this is a single call.
        await search(query)?.poster_path
    }

    private func stillPath(seriesID: String, season: Int, episode: Int) async -> String? {
        guard let url = url("/3/tv/\(seriesID)/season/\(season)/episode/\(episode)/images") else { return nil }
        let response = await MetadataHTTP.get(StillsResponse.self, url: url, headers: authHeaders)
        return Self.bestImagePath(response?.stills, preferNeutral: true)
    }

    /// Resolves a TMDb id, preferring a stamped id (`Tmdb`, or `SeriesTmdb` for
    /// episodes/seasons) over a title search.
    /// Billed cast, best-first, or `[]`.
    ///
    /// TV uses `aggregate_credits`, which merges a person's roles across every
    /// season — the plain `credits` endpoint returns only the *first* season's
    /// billing, so a later-season regular would be missing from a show the viewer
    /// is midway through.
    public func cast(for query: MetadataQuery, limit: Int = 40) async -> [MediaPerson] {
        guard isEnabled, limit > 0, let id = await resolveID(for: query) else { return [] }
        let isTV = query.isTV
        let path = isTV
            ? "/3/tv/\(id)/aggregate_credits"
            : "/3/movie/\(id)/credits"
        guard let url = url(path),
              let response = await MetadataHTTP.get(CreditsResponse.self, url: url, headers: authHeaders)
        else { return [] }

        return (response.cast ?? []).prefix(limit).compactMap { entry -> MediaPerson? in
            guard let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, let personID = entry.id
            else { return nil }
            // A TV entry carries `roles`; a film entry carries `character`.
            let rawRole = (entry.roles?.first?.character ?? entry.character)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let role = (rawRole?.isEmpty ?? true) ? nil : rawRole
            return MediaPerson(
                id: "tmdb:person:\(personID)",
                name: name,
                role: role,
                kind: "Actor",
                imageURL: entry.profile_path.flatMap { URL(string: "\(imageBase)/w342\($0)") }
            )
        }
    }

    /// Titles TMDb considers related, best-first.
    ///
    /// Prefers `/recommendations` (personalised-style, curated from user behaviour)
    /// and falls back to `/similar` (genre/keyword overlap), which is what a title
    /// too obscure for recommendations still has.
    public func relatedTitles(for query: MetadataQuery, limit: Int) async -> [RelatedTitle] {
        guard isEnabled, limit > 0, let id = await resolveID(for: query) else { return [] }
        let isTV = query.isTV
        let path = "/3/\(isTV ? "tv" : "movie")/\(id)"
        for endpoint in ["recommendations", "similar"] {
            guard let url = url("\(path)/\(endpoint)") else { continue }
            let page = await MetadataHTTP.get(RelatedResponse.self, url: url, headers: authHeaders)
            let mapped = (page?.results ?? []).compactMap { result -> RelatedTitle? in
                guard let name = (result.name ?? result.title)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                    let tmdbID = result.id
                else { return nil }
                return RelatedTitle(
                    title: name,
                    year: Self.year(from: result.first_air_date ?? result.release_date),
                    kind: isTV ? .series : .movie,
                    relation: .recommendation,
                    providerIDs: [ProviderIDNamespace.tmdb.canonicalKey: String(tmdbID)],
                    posterURL: result.poster_path.flatMap { URL(string: "\(imageBase)/w500\($0)") },
                    source: .tmdb
                )
            }
            if !mapped.isEmpty { return Array(mapped.prefix(limit)) }
        }
        return []
    }

    static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    private func resolveID(for query: MetadataQuery, forceTV: Bool = false) async -> String? {
        if let stamped = stampedID(for: query, forceTV: forceTV) { return stamped }
        return await search(query, forceTV: forceTV)?.id.map(String.init)
    }

    /// Exact TMDb id already carried by the item/query, if any.
    ///
    /// An episode/season's own `Tmdb` id names the child rather than the show, so
    /// TV queries prefer `SeriesTmdb` and only trust plain `Tmdb` on a series.
    private func stampedID(
        for query: MetadataQuery,
        forceTV: Bool = false
    ) -> String? {
        let isTV = forceTV || query.isTV
        if isTV,
           let series = query.providerIDs.providerID(.seriesTmdb),
           !series.isEmpty {
            return series
        }
        switch query.kind {
        case .movie, .video, .series:
            if let own = query.providerIDs.providerID(.tmdb), !own.isEmpty {
                return own
            }
        default:
            break
        }
        return nil
    }

    static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func search(_ query: MetadataQuery, forceTV: Bool = false) async -> SearchResult? {
        let isTV = forceTV || query.isTV
        guard let escaped = metadataEscaped(query.title) else { return nil }
        var path = "/3/search/\(isTV ? "tv" : "movie")?query=\(escaped)&include_adult=false"
        if let year = query.year {
            path += "&\(isTV ? "first_air_date_year" : "year")=\(year)"
        }
        guard let url = url(path) else { return nil }
        let results = await MetadataHTTP.get(
            SearchResponse.self, url: url, headers: authHeaders
        )?.results ?? []
        return Self.bestMatch(for: query, among: results)
    }

    /// The result that is actually the title asked for.
    ///
    /// TMDb ranks search results by POPULARITY, not by how well they match — so
    /// taking the first one silently returns the most famous title containing
    /// the words. Searching "The Circle" (2017) returns Kingsman: The Golden
    /// Circle above it, and the page then showed one film under the other's
    /// name. The wrong answer is worse than none here, because nothing on screen
    /// says it was a guess.
    ///
    /// An exact title match wins, preferring one whose year also agrees; failing
    /// that, TMDb's own order stands, since a title the viewer's server spells
    /// differently is still usually the popular one.
    static func bestMatch(for query: MetadataQuery, among results: [SearchResult]) -> SearchResult? {
        let wanted = MediaItemIdentity.normalizedTitle(query.title)
        guard !wanted.isEmpty else { return results.first }
        let exact = results.filter {
            guard let title = $0.displayTitle else { return false }
            return MediaItemIdentity.normalizedTitle(title) == wanted
        }
        guard !exact.isEmpty else { return results.first }
        if let year = query.year, let dated = exact.first(where: { $0.year == year }) {
            return dated
        }
        return exact.first
    }

    private func images(forID id: String, isTV: Bool) async -> ImagesResponse? {
        guard let url = url("/3/\(isTV ? "tv" : "movie")/\(id)/images") else { return nil }
        return await MetadataHTTP.get(ImagesResponse.self, url: url, headers: authHeaders)
    }

    private func movieReleaseDates(
        id: String,
        regionCode: String
    ) async -> [TitleReleaseEvent] {
        guard let url = url("/3/movie/\(id)/release_dates"),
              let response = await MetadataHTTP.get(
                  ReleaseDatesResponse.self,
                  url: url,
                  headers: authHeaders
              ),
              let region = response.results.first(where: {
                  $0.iso_3166_1?.uppercased() == regionCode
              }) else { return [] }

        var seen = Set<String>()
        return region.release_dates.compactMap { release in
            guard let kind = Self.releaseKind(release.type),
                  let date = Self.releaseDate(release.release_date) else {
                return nil
            }
            let key = "\(kind.rawValue)|\(date.timeIntervalSinceReferenceDate)"
            guard seen.insert(key).inserted else { return nil }
            return TitleReleaseEvent(
                kind: kind,
                date: date,
                regionCode: regionCode,
                certification: release.certification?.tmdbNonEmpty,
                note: release.note?.tmdbNonEmpty
            )
        }
        .sorted { $0.date < $1.date }
    }

    private func watchOffers(
        id: String,
        isTV: Bool,
        regionCode: String
    ) async -> (offers: [TitleWatchOffer], link: URL?) {
        guard let url = url("/3/\(isTV ? "tv" : "movie")/\(id)/watch/providers"),
              let response = await MetadataHTTP.get(
                  WatchProvidersResponse.self,
                  url: url,
                  headers: authHeaders
              ),
              let region = response.results[regionCode] else {
            return ([], nil)
        }

        let groups: [(TitleWatchOffer.Kind, [WatchProvider]?)] = [
            (.subscription, region.flatrate),
            (.free, region.free),
            (.ads, region.ads),
            (.rent, region.rent),
            (.buy, region.buy),
        ]
        var seen = Set<String>()
        let offers = groups.flatMap { kind, providers in
            (providers ?? []).compactMap { provider -> TitleWatchOffer? in
                guard let providerID = provider.provider_id,
                      let name = provider.provider_name?.tmdbNonEmpty else {
                    return nil
                }

                let key = "\(kind.rawValue)|\(providerID)"
                guard seen.insert(key).inserted else { return nil }
                return TitleWatchOffer(
                    providerID: providerID,
                    providerName: name,
                    kind: kind,
                    regionCode: regionCode,
                    logoURL: provider.logo_path.flatMap {
                        URL(string: "\(imageBase)/w92\($0)")
                    }
                )
            }
        }

        return (offers, region.link.flatMap(URL.init(string:)))
    }

    static func releaseDate(_ value: String?) -> Date? {
        guard let value, value.count >= 10 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // TMDb release records are civil dates. Parse in the viewer's timezone
        // instead of treating midnight UTC as an instant (which displays the
        // previous day in the Americas).
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }

    static func releaseKind(_ raw: Int?) -> TitleReleaseEvent.Kind? {
        switch raw {
        case 1: .premiere
        case 2: .theatricalLimited
        case 3: .theatrical
        case 4: .digital
        case 5: .physical
        case 6: .television
        default: nil
        }
    }

    /// Builds a TMDb API URL against `apiBase`, attaching the bearer token only in
    /// direct-token mode (the proxy injects auth itself).
    private func url(_ path: String) -> URL? {
        URL(string: apiBase + path)
    }

    // MARK: - Selection (pure, shared with the legacy resolver's logic)

    static func bestImagePath(_ images: [Image]?, preferNeutral: Bool) -> String? {
        rankedImagePaths(images, preferNeutral: preferNeutral, limit: 1).first
    }

    /// The usable image paths ranked best-first (neutral/`en` language preferred,
    /// then by vote average), capped at `limit`. Shared by ``bestImagePath`` and the
    /// backdrop candidate-set path so both use identical selection logic.
    static func rankedImagePaths(_ images: [Image]?, preferNeutral: Bool, limit: Int) -> [String] {
        guard let images, limit > 0 else { return [] }
        let usable = images.filter { ($0.file_path?.isEmpty == false) }
        guard !usable.isEmpty else { return [] }
        func rank(_ image: Image) -> Int {
            switch image.iso_639_1 {
            case nil, "": return preferNeutral ? 0 : 1
            case "en": return preferNeutral ? 1 : 0
            default: return 2
            }
        }
        return usable.sorted {
            let (lr, rr) = (rank($0), rank($1))
            if lr != rr { return lr < rr }
            return ($0.vote_average ?? 0) > ($1.vote_average ?? 0)
        }.prefix(limit).compactMap(\.file_path)
    }

    static func bestLogoPath(_ logos: [Image]?) -> String? {
        guard let logos else { return nil }
        let usable = logos.filter {
            guard let p = $0.file_path, !p.isEmpty else { return false }
            return !p.lowercased().hasSuffix(".svg")
        }
        guard !usable.isEmpty else { return nil }
        func rank(_ image: Image) -> Int {
            switch image.iso_639_1 {
            case "en": return 0
            case nil, "": return 1
            default: return 2
            }
        }
        return usable.sorted {
            let (lr, rr) = (rank($0), rank($1))
            if lr != rr { return lr < rr }
            return ($0.vote_average ?? 0) > ($1.vote_average ?? 0)
        }.first?.file_path
    }

    // MARK: - DTOs

    struct SearchResponse: Decodable {
        let results: [SearchResult]
    }
    struct SearchResult: Decodable {
        let id: Int?
        let poster_path: String?
        /// Films carry `title`, series carry `name`.
        let title: String?
        let name: String?
        let release_date: String?
        let first_air_date: String?
        let original_language: String?

        var displayTitle: String? { title ?? name }
        var year: Int? { Int((release_date ?? first_air_date)?.prefix(4) ?? "") }
    }
    struct OriginalLanguageResponse: Decodable {
        let original_language: String?
    }
    struct ReleaseDatesResponse: Decodable {
        let results: [ReleaseRegion]
    }
    struct ReleaseRegion: Decodable {
        let iso_3166_1: String?
        let release_dates: [ReleaseDate]
    }
    struct ReleaseDate: Decodable {
        let certification: String?
        let note: String?
        let release_date: String?
        let type: Int?
    }
    struct WatchProvidersResponse: Decodable {
        let results: [String: WatchProviderRegion]
    }
    struct WatchProviderRegion: Decodable {
        let link: String?
        let flatrate: [WatchProvider]?
        let free: [WatchProvider]?
        let ads: [WatchProvider]?
        let rent: [WatchProvider]?
        let buy: [WatchProvider]?
    }
    struct WatchProvider: Decodable {
        let provider_id: Int?
        let provider_name: String?
        let logo_path: String?
    }
    struct CreditsResponse: Decodable {
        let cast: [CreditEntry]?
    }
    struct CreditEntry: Decodable {
        let id: Int?
        let name: String?
        let character: String?
        let profile_path: String?
        let roles: [CreditRole]?
    }
    struct CreditRole: Decodable {
        let character: String?
    }
    struct RelatedResponse: Decodable {
        let results: [RelatedResult]?
    }
    struct RelatedResult: Decodable {
        let id: Int?
        let name: String?
        let title: String?
        let poster_path: String?
        let first_air_date: String?
        let release_date: String?
    }
    struct ImagesResponse: Decodable {
        let backdrops: [Image]?
        let logos: [Image]?
    }
    struct StillsResponse: Decodable {
        let stills: [Image]?
    }
    struct Image: Decodable {
        let file_path: String?
        let iso_639_1: String?
        let vote_average: Double?
    }
}

private extension String {
    var tmdbNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
