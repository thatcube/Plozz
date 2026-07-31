#if canImport(Foundation)
import Foundation
import CoreModels

/// Titles featuring a person, from somewhere OTHER than the viewer's servers.
///
/// The last rung of the credits ladder, and the only one that can answer for a
/// viewer whose libraries are network shares — those have no person records at
/// all, so nothing before this can say a word about who is on screen.
///
/// Everything it returns is by definition *not* in the library, and is marked
/// so: `availability == .unknown`, which `isNotInLibraryDiscovery` reads.
public protocol PersonCreditsProviding: Sendable {
    /// Best-effort. A provider that cannot identify the person returns `[]`.
    func credits(for name: String, limit: Int) async -> [MediaItem]

    /// Shown in the UI when this provider's results are displayed. TVmaze's
    /// CC BY-SA licence requires attribution; a provider that needs none returns
    /// `nil`.
    var attribution: String? { get }
}

/// TVmaze — keyless, no account, no registration.
///
/// Television only: it indexes broadcast, cable and streaming series and does
/// not carry theatrical film. That is a real limit, and the reason this sits
/// BELOW every server in the ladder rather than replacing any of them.
///
/// Chosen because it covers people the other open sources miss. Measured against
/// three actors no server could answer for, none of whom has a Wikipedia
/// article: Laurel Lefkow (15 credits, ALL of them guest parts), Harry Ditson
/// (2 regular, 6 guest), John Strong (matched at 1.0, but zero credits of
/// either kind).
///
/// John Strong is the honest limit of this: TVmaze knowing a person is not the
/// same as TVmaze knowing what they were in, and no fallback below this rung
/// helps — Wikidata has two people by that name and so declines to guess. Some
/// cast members will show nothing, and the row has to read acceptably when they
/// do.
public struct TVmazePersonCreditsProvider: PersonCreditsProviding {
    private let host = "https://api.tvmaze.com"
    /// Below this the match is a guess. TVmaze scores an exact name 1.0 and
    /// drops sharply for near-misses ("Harry Ditson" → "Larry Jack Dotson" at
    /// 0.27), so the threshold does real work.
    private let minimumScore = 0.85

    public init() {}

    public var attribution: String? { "TVmaze" }

    public func credits(for name: String, limit: Int) async -> [MediaItem] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let personID = await resolvePerson(name: trimmed) else { return [] }

        // Both lists, because for exactly the obscure actors this provider
        // exists to cover, `castcredits` is often empty and everything they did
        // is a one-episode guest part. Fetching only the regular credits was
        // measured returning nothing for people TVmaze knows well.
        async let regular = regularCredits(personID: personID)
        async let guest = guestCredits(personID: personID)
        let all = await regular + guest

        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }.prefix(max(1, limit)).map { $0 }
    }

    private func resolvePerson(name: String) async -> Int? {
        var components = URLComponents(string: "\(host)/search/people")
        components?.queryItems = [URLQueryItem(name: "q", value: name)]
        guard let url = components?.url,
              let results = await MetadataHTTP.get([SearchResult].self, url: url)
        else { return nil }
        guard let best = results.first, best.score >= minimumScore else { return nil }
        return best.person.id
    }

    private func regularCredits(personID: Int) async -> [MediaItem] {
        guard let url = URL(string: "\(host)/people/\(personID)/castcredits?embed=show"),
              let credits = await MetadataHTTP.get([CastCredit].self, url: url)
        else { return [] }
        return credits.compactMap { credit in
            guard let show = credit.embedded?.show else { return nil }
            return item(id: show.id, title: show.name, year: show.premiered, image: show.image?.medium)
        }
    }

    /// Guest credits cannot be embedded with `embed=show` — TVmaze answers that
    /// with an error object rather than a list. Embedding the episode instead
    /// still yields the show: its `_links.show` carries both the name and the
    /// href the id is parsed from, so this stays one request rather than one
    /// per episode.
    private func guestCredits(personID: Int) async -> [MediaItem] {
        guard let url = URL(string: "\(host)/people/\(personID)/guestcastcredits?embed=episode"),
              let credits = await MetadataHTTP.get([GuestCredit].self, url: url)
        else { return [] }
        return credits.compactMap { credit in
            guard let episode = credit.embedded?.episode,
                  let show = episode.links?.show,
                  let name = show.name,
                  let id = show.href.split(separator: "/").last.flatMap({ Int($0) })
            else { return nil }
            // The episode's airdate, not the show's premiere, which this shape
            // does not carry. For a guest part that is the more useful date
            // anyway: it says when the viewer would have seen them.
            return item(id: id, title: name, year: episode.airdate, image: nil)
        }
    }

    private func item(id: Int, title: String, year: String?, image: String?) -> MediaItem {
        var item = MediaItem(id: "tvmaze:\(id)", title: title, kind: .series)
        item.productionYear = year.flatMap { Int($0.prefix(4)) }
        item.posterURL = image.flatMap(URL.init(string:))
        item.availability = .unknown
        return item
    }

    private struct SearchResult: Decodable {
        let score: Double
        let person: Person
        struct Person: Decodable { let id: Int }
    }

    private struct CastCredit: Decodable {
        let embedded: Embedded?
        enum CodingKeys: String, CodingKey { case embedded = "_embedded" }
        struct Embedded: Decodable { let show: Show? }
        struct Show: Decodable {
            let id: Int
            let name: String
            let premiered: String?
            let image: Image?
            struct Image: Decodable { let medium: String? }
        }
    }

    private struct GuestCredit: Decodable {
        let embedded: Embedded?
        enum CodingKeys: String, CodingKey { case embedded = "_embedded" }
        struct Embedded: Decodable { let episode: Episode? }
        struct Episode: Decodable {
            let airdate: String?
            let links: Links?
            enum CodingKeys: String, CodingKey { case airdate, links = "_links" }
            struct Links: Decodable { let show: Show? }
            struct Show: Decodable {
                let href: String
                let name: String?
            }
        }
    }
}

/// Wikidata — **CC0**, keyless, and the only open source here that covers film
/// as well as television.
///
/// Ranked by `wikibase:sitelinks`: how many Wikipedia editions carry an article
/// about the work. That is a genuine fame signal rather than a proxy for one —
/// asking for Morgan Freeman returns The Dark Knight and The Shawshank
/// Redemption first, which is what "known for" means.
///
/// Pairs with TVmaze rather than replacing it. TVmaze indexes episode-level
/// guest work Wikidata has no entity for, and Wikidata has the films TVmaze does
/// not carry at all. Neither is load-bearing alone, which is the point: nothing
/// in this app should depend on a single outside source.
public struct WikidataPersonCreditsProvider: PersonCreditsProviding {
    private let endpoint = "https://query.wikidata.org/sparql"

    public init() {}

    /// CC0 requires none, which is part of why it is preferred.
    public var attribution: String? { nil }

    public func credits(for name: String, limit: Int) async -> [MediaItem] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A quote would terminate the literal in the query below. These are
        // interpolated into SPARQL, so the guard is the injection boundary, not
        // a tidiness check — and a backslash escapes the closing quote just as
        // effectively as a quote does.
        guard !trimmed.isEmpty,
              !trimmed.contains("\""),
              !trimmed.contains("\\")
        else { return [] }
        guard let qid = await resolveQID(name: trimmed) else { return [] }

        // GROUP BY, because a work with several release dates (a premiere and a
        // wide release, say) otherwise returns one row per date, and the first
        // page of results is then the same title repeated five times.
        let query = """
        SELECT ?work ?workLabel (MIN(?y) AS ?year) (SAMPLE(?sitelinks) AS ?links) WHERE {
          ?work wdt:P161 wd:\(qid); wikibase:sitelinks ?sitelinks.
          OPTIONAL { ?work wdt:P577 ?d. BIND(YEAR(?d) AS ?y) }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        GROUP BY ?work ?workLabel
        ORDER BY DESC(?links)
        LIMIT \(max(1, limit))
        """

        guard let response = await run(query) else { return [] }
        return response.results.bindings.compactMap { row -> MediaItem? in
            guard let id = row.work?.value.split(separator: "/").last.map(String.init),
                  let title = row.workLabel?.value, !title.isEmpty,
                  // An unlabelled entity comes back labelled as its own QID;
                  // showing "Q12345" as a title is worse than dropping the row.
                  title != id
            else { return nil }
            var item = MediaItem(id: "wikidata:\(id)", title: title, kind: .movie)
            item.productionYear = row.year.flatMap { Int($0.value) }
            // No artwork: `P18` is a Commons filename needing a second request
            // each, and the title tile the row already falls back to is a better
            // trade than a burst of image lookups during playback.
            item.availability = .unknown
            return item
        }
    }

    /// Resolves a name to exactly one entity, or to nothing at all.
    ///
    /// Namesakes are the whole problem here: Wikidata holds seven people
    /// labelled "David Warner" and at least ten labelled "John Williams".
    /// Because the credits query ranks by sitelinks, a name matching two actors
    /// would quietly return whichever is more famous — so asking about an
    /// obscure player would produce a Hollywood filmography, presented as fact.
    ///
    /// Requiring a `P161` credit does the real work: it drops the priests,
    /// politicians and mathematicians sharing the name. Occupation (`P106`)
    /// looks like the natural filter and measured worse — Wikidata tags cameos
    /// as acting, so the cricketer David Warner passes it, while a genuinely
    /// obscure actor with a sparse entity fails it.
    ///
    /// When more than one candidate survives, this returns nothing rather than
    /// picking one. That matches the same judgement made in
    /// `WikipediaPersonBiographyProvider.isPlausiblePerson`: wrong information
    /// under someone's headshot is worse than an empty row, because nothing on
    /// screen marks it as a guess.
    private func resolveQID(name: String) async -> String? {
        let query = """
        SELECT DISTINCT ?person WHERE {
          ?person wdt:P31 wd:Q5; rdfs:label "\(name)"@en.
          ?w wdt:P161 ?person.
        }
        LIMIT 2
        """
        guard let response = await run(query) else { return nil }
        let ids = response.results.bindings.compactMap {
            $0.person?.value.split(separator: "/").last.map(String.init)
        }
        guard ids.count == 1 else { return nil }
        return ids[0]
    }

    private func run(_ query: String) async -> SPARQLResponse? {
        var components = URLComponents(string: endpoint)
        components?.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components?.url else { return nil }
        return await MetadataHTTP.get(
            SPARQLResponse.self,
            url: url,
            accept: "application/sparql-results+json"
        )
    }

    private struct SPARQLResponse: Decodable {
        let results: Results
        struct Results: Decodable {
            let bindings: [Binding]
        }
        struct Binding: Decodable {
            let person: Value?
            let work: Value?
            let workLabel: Value?
            let year: Value?
        }
        struct Value: Decodable {
            let value: String
        }
    }
}

#endif
