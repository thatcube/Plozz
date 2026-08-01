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

    /// television series, miniseries, television programme, television special.
    /// Everything else in the whitelist is a film of some sort. Without this a
    /// row of Martin Freeman's work labels Sherlock and Fargo as films.
    private static let televisionTypes: Set<String> = [
        "Q5398426", "Q1259759", "Q15416", "Q1261214",
    ]

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
        // Filtered to watchable types SERVER-side, which matters because the
        // limit is applied after ranking: unfiltered, "P161" also matches film
        // posters, production companies, individual episodes, SNL sketches and
        // "The Hobbit trilogy" (a collection, not something you can play), and
        // that noise eats the handful of slots the row actually has.
        //
        // A whitelist rather than a blacklist. Enumerating the junk was tried
        // and there is no end to it; enumerating what a person can sit and watch
        // is a short, stable list.
        //
        // Award-cited works lead. An award or nomination records WHICH work it
        // was for, so it is the one prominence signal Wikidata carries that is
        // both meaningful and reasonably common — measured on 13 of 17 people,
        // where billing order managed 8%. It surfaces exactly what ranking by
        // the fame of the work buries: Luther for Idris Elba, The Americans for
        // Margo Martindale, The Office and Fargo for Martin Freeman.
        //
        // Actors who are never nominated — character and motion-capture
        // performers especially — simply fall through to the sitelinks order.
        let query = """
        SELECT ?work ?workLabel (MIN(?y) AS ?year) (SAMPLE(?sitelinks) AS ?links)
               (SAMPLE(?type) AS ?kind) (COUNT(?award) AS ?awarded) WHERE {
          VALUES ?type {
            wd:Q11424 wd:Q506240 wd:Q24862
            wd:Q5398426 wd:Q1259759 wd:Q15416 wd:Q1261214
          }
          ?work wdt:P161 wd:\(qid); wikibase:sitelinks ?sitelinks; wdt:P31 ?type.
          OPTIONAL { ?work wdt:P577 ?d. BIND(YEAR(?d) AS ?y) }
          OPTIONAL { wd:\(qid) p:P166|p:P1411 ?award. ?award pq:P1686 ?work. }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        GROUP BY ?work ?workLabel
        ORDER BY DESC(?awarded) DESC(?links)
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
            let type = row.kind?.value.split(separator: "/").last.map(String.init)
            var item = MediaItem(
                id: "wikidata:\(id)",
                title: title,
                kind: Self.televisionTypes.contains(type ?? "") ? .series : .movie
            )
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
            let kind: Value?
        }
        struct Value: Decodable {
            let value: String
        }
    }
}

/// TMDb — the only source measured that knows how *prominent* a person was in a
/// title, rather than only how famous the title is.
///
/// That distinction is the whole problem. Ranking by the fame of the work puts
/// Martin Freeman's Everett Ross in Black Panther above John Watson in Sherlock,
/// because the film is more famous than the series — but nobody would say he is
/// known for Black Panther. `order` (billing position) and `episode_count` are
/// what separate a lead from a walk-on, and TMDb carries billing for roughly
/// two thirds of credits where Wikidata carries it for 8%.
///
/// Measured against every other option, this is also the only one with no
/// coverage holes: it resolved all fifteen people tested, including Brian Cox
/// and Laurel Lefkow, whom Wikidata refuses because their names are ambiguous.
///
/// NOT load-bearing despite that. It needs a key, so it is absent from keyless
/// builds and can be rate-limited or down, and the rungs below it are keyless by
/// design and keep answering when it cannot.
///
/// Deliberately ignores TMDb's own `known_for` field, which was measured and is
/// poor: it offers Zootopia and The Dark Tower for Idris Elba, omits Succession
/// for Brian Cox, and gives Margo Martindale's as Hannah Montana. The raw
/// credits are excellent; the precomputed summary of them is not.
public struct TMDbPersonCreditsProvider: PersonCreditsProviding {
    private let access: TMDbAccess

    public init(access: TMDbAccess) {
        self.access = access
    }

    public var attribution: String? { "TMDB" }

    private var apiBase: String {
        switch access {
        case .proxy(let url):
            let text = url.absoluteString
            return text.hasSuffix("/") ? String(text.dropLast()) : text
        case .directToken, .userToken, .disabled:
            return "https://api.themoviedb.org"
        }
    }

    private var authHeaders: [String: String] {
        switch access {
        case .directToken(let token), .userToken(let token):
            return ["Authorization": "Bearer \(token)"]
        case .proxy, .disabled:
            return [:]
        }
    }

    public func credits(for name: String, limit: Int) async -> [MediaItem] {
        guard access.isEnabled else { return [] }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let personID = await resolvePerson(name: trimmed) else { return [] }
        guard let url = URL(string: "\(apiBase)/3/person/\(personID)/combined_credits"),
              let response = await MetadataHTTP.get(CreditsResponse.self, url: url, headers: authHeaders)
        else { return [] }

        return (response.cast ?? [])
            .filter { $0.qualifies }
            .sorted { $0.knownForScore > $1.knownForScore }
            .prefix(max(1, limit))
            .compactMap { credit in
                guard let title = credit.displayTitle else { return nil }
                let isTV = credit.mediaType == "tv"
                var item = MediaItem(
                    id: "tmdb:\(isTV ? "tv" : "movie"):\(credit.id)",
                    title: title,
                    kind: isTV ? .series : .movie
                )
                // The id TMDb itself gave us, stamped where enrichment looks for
                // it.
                //
                // Without this the detail page has only a title to go on and
                // searches for it — and TMDb ranks search by popularity, so
                // "The Circle" resolves to Kingsman: The Golden Circle and the
                // page fills with the wrong film's artwork and synopsis. An
                // exact id cannot be misread, and it skips the search entirely.
                item.providerIDs[ProviderIDNamespace.tmdb.canonicalKey] = String(credit.id)
                if isTV {
                    // Series enrichment reads the series-scoped key, since an
                    // episode's own id is not the show's.
                    item.providerIDs[ProviderIDNamespace.seriesTmdb.canonicalKey] = String(credit.id)
                }
                item.productionYear = credit.year
                item.posterURL = credit.posterPath.flatMap {
                    URL(string: "https://image.tmdb.org/t/p/w342\($0)")
                }
                item.availability = .unknown
                return item
            }
    }

    private func resolvePerson(name: String) async -> Int? {
        var components = URLComponents(string: "\(apiBase)/3/search/person")
        components?.queryItems = [URLQueryItem(name: "query", value: name)]
        guard let url = components?.url,
              let response = await MetadataHTTP.get(
                  PersonSearchResponse.self, url: url, headers: authHeaders
              )
        else { return nil }
        // TMDb orders by its own relevance and puts an exact name first. Unlike
        // the Wikidata rung there is no namesake guard here: TMDb ranks by
        // popularity within a name, and refusing ambiguous names would lose
        // Brian Cox, who is only ambiguous because a physicist shares his name.
        return response.results?.first { $0.name?.caseInsensitiveCompare(name) == .orderedSame }?.id
            ?? response.results?.first?.id
    }

    private struct PersonSearchResponse: Decodable {
        let results: [Person]?
        struct Person: Decodable {
            let id: Int
            let name: String?
        }
    }

    private struct CreditsResponse: Decodable {
        let cast: [Credit]?
    }

    struct Credit: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let mediaType: String?
        let order: Int?
        let episodeCount: Int?
        let voteCount: Int?
        let posterPath: String?
        let releaseDate: String?
        let firstAirDate: String?

        enum CodingKeys: String, CodingKey {
            case id, title, name, order
            case mediaType = "media_type"
            case episodeCount = "episode_count"
            case voteCount = "vote_count"
            case posterPath = "poster_path"
            case releaseDate = "release_date"
            case firstAirDate = "first_air_date"
        }

        var displayTitle: String? {
            let text = (title ?? name)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }

        var year: Int? {
            Int((releaseDate ?? firstAirDate)?.prefix(4) ?? "")
        }

        /// Excludes the long tail of one-line parts and unreleased projects that
        /// otherwise crowd out real work. A recurring television role is kept
        /// regardless of votes, because episode count is itself the evidence.
        ///
        /// 800 is high, and lowering it to 100 was tried and measurably worse:
        /// five of ten people changed inside the top twelve, and the changes ran
        /// the wrong way — Hailee Steinfeld lost Hawkeye to Romeo & Juliet, and
        /// Clancy Brown lost Rick and Morty to The Mortuary Collection. Billing
        /// is per-title, so a lead role in a film nobody rated outscores a
        /// well-known supporting one the moment the floor lets it in.
        ///
        /// The tail this excludes has no artwork attached once another source
        /// supplies it, which is a real cost — but the answer to that is to
        /// backfill artwork, not to degrade the ranking to obtain it.
        var qualifies: Bool {
            displayTitle != nil && ((voteCount ?? 0) >= 800 || (episodeCount ?? 0) >= 10)
        }

        /// Fame of the work, damped, multiplied by how prominent the person was
        /// in it.
        ///
        /// The exponent is the whole argument. At 1.0 the vote count dominates
        /// and the ranking collapses back into "famous things they appeared in"
        /// — Idris Elba loses The Wire to Zootopia. Below about 0.5 billing
        /// dominates instead and a lead role in a forgotten film outranks
        /// everything. 0.6 was picked by comparing the top five for fifteen
        /// people against what those actors are actually known for.
        var knownForScore: Double {
            let votes = Double(voteCount ?? 0)
            // An absent billing position is treated as mid-cast rather than as
            // a lead: TMDb omits `order` for most television, and defaulting it
            // to 0 would rank every guest appearance as a starring role.
            let billing = 1.0 / (1.0 + Double(order ?? 8))
            // A regular on 40+ episodes is as prominent as a film lead, and
            // capping there stops a 600-episode cartoon run from dwarfing
            // everything else purely on longevity.
            let recurring = mediaType == "tv" ? min(Double(episodeCount ?? 0), 40) / 40 : 0
            return pow(votes, 0.6) * (billing + recurring)
        }
    }
}

#endif

/// Finds artwork for a title that arrived without any.
///
/// Separate from `PersonCreditsProviding` on purpose. Which titles a person is
/// known for and what those titles look like are different questions, and tying
/// them together is what went wrong before: the rung with the best artwork had
/// its ranking floor lowered to reach further down the row, and the ranking got
/// measurably worse — a lead role in a film nobody rated outscored a well-known
/// supporting one. Rank first, then decorate.
public protocol PersonCreditArtworkResolving: Sendable {
    /// `nil` when nothing is found, which must stay cheap: most of the row
    /// already has artwork and only the tail asks.
    func posterURL(title: String, year: Int?, isSeries: Bool) async -> URL?
}

/// TMDb's search endpoints, used only to put a face on a title another source
/// named.
///
/// Its own credits rung deliberately ignores work below a vote floor, because
/// letting it in wrecked the ranking. Those titles still reach the row from
/// Wikidata and TVmaze, and TMDb almost always has a poster for them — so this
/// asks the same service the question it is good at, without letting it move
/// anything.
public struct TMDbPersonCreditArtworkResolver: PersonCreditArtworkResolving {
    private let access: TMDbAccess

    public init(access: TMDbAccess) {
        self.access = access
    }

    public func posterURL(title: String, year: Int?, isSeries: Bool) async -> URL? {
        guard access.isEnabled else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let base: String
        switch access {
        case .proxy(let url):
            let text = url.absoluteString
            base = text.hasSuffix("/") ? String(text.dropLast()) : text
        case .directToken, .userToken, .disabled:
            base = "https://api.themoviedb.org"
        }
        var headers: [String: String] = [:]
        if case .directToken(let token) = access { headers["Authorization"] = "Bearer \(token)" }
        if case .userToken(let token) = access { headers["Authorization"] = "Bearer \(token)" }

        // With the year first, then without it.
        //
        // A year is a strong discriminator between remakes sharing a title, so
        // it is worth trying — but the sources disagree about it often enough
        // (a premiere against a wide release, a scanner's guess) that requiring
        // one drops matches that are otherwise exact. Measured over 600 credits,
        // the retry is what lifts coverage the last stretch.
        for attemptYear in [year, nil] {
            var components = URLComponents(
                string: "\(base)/3/search/\(isSeries ? "tv" : "movie")"
            )
            var query = [URLQueryItem(name: "query", value: trimmed)]
            if let attemptYear {
                query.append(URLQueryItem(
                    name: isSeries ? "first_air_date_year" : "year",
                    value: String(attemptYear)
                ))
            }
            components?.queryItems = query
            guard let url = components?.url,
                  let response = await MetadataHTTP.get(
                      SearchResponse.self, url: url, headers: headers
                  )
            else { continue }
            let matches = response.results ?? []
            // An exact title match anywhere in the results beats a fuzzy one at
            // the top: TMDb ranks by popularity, so searching a modest title can
            // return a more famous near-miss first, and the wrong poster is
            // worse than none.
            let exact = matches.first {
                $0.displayTitle?.caseInsensitiveCompare(trimmed) == .orderedSame
            }
            if let path = (exact ?? matches.first)?.posterPath {
                return URL(string: "https://image.tmdb.org/t/p/w342\(path)")
            }
            // Nothing more to try when there was no year to drop.
            if year == nil { break }
        }
        return nil
    }

    private struct SearchResponse: Decodable {
        let results: [Match]?
        struct Match: Decodable {
            let title: String?
            let name: String?
            let posterPath: String?
            enum CodingKeys: String, CodingKey {
                case title, name
                case posterPath = "poster_path"
            }
            var displayTitle: String? { title ?? name }
        }
    }
}
