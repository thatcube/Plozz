import Foundation

/// Resolved TheTVDB metadata for a title (the neutral result the share enricher
/// consumes). All fields best-effort; a partial result still helps.
public struct TVDBMetadata: Sendable, Equatable {
    public var tvdbID: String?
    public var imdbID: String?
    public var tmdbID: String?
    public var overview: String?
    public var posterURL: URL?
    public var genres: [String]
    public var year: Int?
    /// The show's canonical name as TheTVDB records it ("Avatar: The Last
    /// Airbender"), used to upgrade a generic folder-derived title ("Avatar").
    public var title: String?
    /// The work's original language as TheTVDB records it (`originalLanguage` on the
    /// extended record, `primary_language` on a search hit) — an ISO-639-2/1 code
    /// like `eng`/`jpn`. Normalized to ISO-639-1 by the enrichment adapter.
    public var originalLanguage: String?

    public init(tvdbID: String? = nil, imdbID: String? = nil, tmdbID: String? = nil,
                overview: String? = nil, posterURL: URL? = nil, genres: [String] = [], year: Int? = nil,
                title: String? = nil, originalLanguage: String? = nil) {
        self.tvdbID = tvdbID
        self.imdbID = imdbID
        self.tmdbID = tmdbID
        self.overview = overview
        self.posterURL = posterURL
        self.genres = genres
        self.year = year
        self.title = title
        self.originalLanguage = originalLanguage
    }
}

/// A per-episode fingerprint from the LOCAL library, used to disambiguate a
/// title collision (e.g. the animated "Archer" vs the 1975 detective drama of the
/// same name) by matching on-disk episode titles against a candidate's episodes.
/// Robust even when only one season was downloaded (season count alone can't tell
/// a 1-season namesake from S1 of a long-running show).
public struct SeriesEpisodeHint: Sendable, Equatable {
    public let season: Int
    public let episode: Int
    public let title: String
    public init(season: Int, episode: Int, title: String) {
        self.season = season
        self.episode = episode
        self.title = title
    }
}

/// Minimal client for **TheTVDB v4** — the bundled keyed metadata/artwork tier.
///
/// Flow: `POST /login` with the project api key → a JWT bearer (~1 month), cached
/// in-memory; then `GET /search?query=…&type=movie|series` with that bearer.
/// One search yields ids (TVDB + IMDb/TMDb from `remote_ids`), overview, a poster
/// (`image_url`) and genres — enough to enrich a share item, especially movies,
/// which have no keyless id/poster source. Never throws; a miss returns `nil`.
///
/// An `actor` so the cached token is mutated safely under concurrent enrichment.
public actor TVDBClient {
    private let config: TVDBConfig
    private var token: String?

    public init(config: TVDBConfig = .resolved()) {
        self.config = config
    }

    public var isConfigured: Bool { config.isConfigured }

    /// Resolve metadata for a title. `year` (when known) disambiguates same-name
    /// results; `episodeHints` (on-disk episode titles) disambiguate a same-name
    /// collision by content when the year is unknown. Returns `nil` when
    /// unconfigured or unmatched.
    public func resolve(
        title: String,
        year: Int?,
        isMovie: Bool,
        episodeHints: [SeriesEpisodeHint] = []
    ) async -> TVDBMetadata? {
        await resolve(titles: [title], year: year, isMovie: isMovie, episodeHints: episodeHints)
    }

    /// Resolve metadata trying SEVERAL candidate titles in order, returning the
    /// first that yields a match. Callers pass the most specific/reliable title
    /// first (e.g. a rich filename title like "Avatar The Last Airbender" ahead of
    /// a generic folder title "Avatar"), so a generic show-folder name still finds
    /// the right series via the filename. Year + episode hints disambiguate within
    /// each candidate's results.
    public func resolve(
        titles: [String],
        year: Int?,
        isMovie: Bool,
        episodeHints: [SeriesEpisodeHint] = []
    ) async -> TVDBMetadata? {
        guard config.isConfigured else { return nil }
        var seen = Set<String>()
        for raw in titles {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, seen.insert(key).inserted else { continue }
            if let result = await search(query: trimmed, year: year, isMovie: isMovie,
                                         episodeHints: episodeHints, allowRelogin: true) {
                return result
            }
        }
        return nil
    }

    /// Resolve metadata DIRECTLY by a known TheTVDB id — the authoritative path when
    /// the library folder carries an explicit `[tvdb-####]` tag, skipping the
    /// ambiguous title search entirely (fixes e.g. the 1999 One Piece anime, tagged
    /// `[tvdb-81797]`, resolving to a wrong same-named entry). Returns nil when
    /// unconfigured or the id doesn't resolve.
    public func resolve(byTVDBID id: String, isMovie: Bool) async -> TVDBMetadata? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.isConfigured, !trimmed.isEmpty, let token = await ensureToken() else { return nil }
        let type = isMovie ? "movies" : "series"
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/\(type)/\(trimmed)/extended") else { return nil }
        let (response, reachable) = await MetadataHTTP.getWithStatus(
            SeriesExtendedResponse.self, url: url, headers: ["Authorization": "Bearer \(token)"]
        )
        guard let data = response?.data else {
            if !reachable { self.token = nil }   // likely-expired token; re-login next time
            return nil
        }
        var imdb: String?
        var tmdb: String?
        for r in data.remoteIds ?? [] {
            guard let source = r.sourceName?.lowercased(), let v = r.id, !v.isEmpty else { continue }
            if source.contains("imdb") { imdb = v }
            else if source.contains("themoviedb") || source == "tmdb" { tmdb = v }
        }
        // The extended record carries the PRIMARY-language name/overview (e.g.
        // Japanese for an anime like One Piece). Prefer the English translation when
        // available so descriptions read in English; fall back to the base fields.
        let english = await translation(type: type, id: trimmed, language: "eng", token: token)
        let overview = (english?.overview ?? data.overview)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let name = (english?.name ?? data.name)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        return TVDBMetadata(
            tvdbID: data.id.map(String.init) ?? trimmed,
            imdbID: imdb,
            tmdbID: tmdb,
            overview: overview,
            posterURL: data.image.flatMap(Self.imageURL),
            genres: (data.genres ?? []).compactMap { $0.name?.nonEmpty },
            year: data.year.flatMap { Int($0) },
            title: name,
            originalLanguage: data.originalLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        )
    }

    /// The series' next scheduled episode by a known TheTVDB id.
    ///
    /// TheTVDB's series record carries `nextAired`, a bare calendar day (no time), so
    /// the schedule is `dateOnly`. We additionally page the series' episodes and match
    /// that day to recover the season/episode/title best-effort — but never guess them
    /// when no episode's `aired` matches. Returns `nil` when unconfigured (keyless),
    /// the id is empty, or there is no future `nextAired`.
    public func nextAired(byTVDBID id: String) async -> ProviderNextEpisode? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.isConfigured, !trimmed.isEmpty, let token = await ensureToken() else { return nil }
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/series/\(trimmed)/extended") else { return nil }
        let (response, reachable) = await MetadataHTTP.getWithStatus(
            SeriesExtendedResponse.self, url: url, headers: ["Authorization": "******"]
        )
        guard let data = response?.data else {
            if !reachable { self.token = nil }
            return nil
        }
        guard let raw = data.nextAired?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              let airDate = ScheduleDateParsing.calendarDate(raw) else { return nil }

        let match = await episodeAiring(on: raw, seriesID: trimmed, token: token)
        return ProviderNextEpisode(
            seasonNumber: match?.season,
            episodeNumber: match?.number,
            title: match?.name,
            airDate: airDate,
            datePrecision: .dateOnly,
            sourceURL: URL(string: "\(config.apiBaseURL.absoluteString)/series/\(trimmed)/extended")
        )
    }

    /// Finds the first episode whose `aired` day equals `day` in the series' default
    /// episode order. Best-effort — returns `nil` (leaving S/E/title unfilled) rather
    /// than guessing when nothing matches.
    private func episodeAiring(on day: String, seriesID: String, token: String)
        async -> (season: Int, number: Int, name: String?)? {
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/series/\(seriesID)/episodes/default?page=0") else { return nil }
        let (response, _) = await MetadataHTTP.getWithStatus(
            EpisodesResponse.self, url: url, headers: ["Authorization": "******"]
        )
        guard let episodes = response?.data?.episodes else { return nil }
        for ep in episodes {
            guard ep.aired == day, let s = ep.seasonNumber, let n = ep.number else { continue }
            return (s, n, ep.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty)
        }
        return nil
    }

    /// Fetch a single-language name/overview translation for a series/movie
    /// (`/{type}/{id}/translations/{language}`). Best-effort; nil on any miss so the
    /// caller falls back to the base record's primary-language fields.
    private func translation(type: String, id: String, language: String, token: String)
        async -> (name: String?, overview: String?)? {
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/\(type)/\(id)/translations/\(language)") else { return nil }
        let (response, _) = await MetadataHTTP.getWithStatus(
            TranslationResponse.self, url: url, headers: ["Authorization": "Bearer \(token)"]
        )
        guard let t = response?.data else { return nil }
        return (t.name?.nonEmpty, t.overview?.nonEmpty)
    }

    /// Resolve a wide **backdrop** (fanart) URL for a title, or `nil`. Uses a known
    /// TVDB id when available (skipping the search), else searches by title/year,
    /// then reads the title's extended record and picks the largest landscape
    /// artwork. TheTVDB has rich fanart for most TV + film, so this fills heroes
    /// that would otherwise have no wide art. Never throws.
    public func backdropURL(title: String, year: Int?, isMovie: Bool, tvdbID: String?) async -> URL? {
        guard config.isConfigured else { return nil }
        let id: String?
        if let tvdbID, !tvdbID.isEmpty {
            id = tvdbID
        } else {
            id = await resolve(title: title, year: year, isMovie: isMovie)?.tvdbID
        }
        guard let id, let token = await ensureToken() else { return nil }
        let type = isMovie ? "movies" : "series"
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/\(type)/\(id)/extended") else { return nil }
        let (response, reachable) = await MetadataHTTP.getWithStatus(
            ExtendedResponse.self, url: url, headers: ["Authorization": "Bearer \(token)"]
        )
        guard let response else {
            if !reachable { self.token = nil }   // likely-expired token; re-login next time
            return nil
        }
        return Self.bestBackdrop(response.data?.artworks ?? [])
    }

    /// Pick the highest-resolution genuinely-landscape artwork (a background/fanart
    /// rather than a poster or square), by aspect + area — avoids relying on
    /// TheTVDB's per-content artwork *type* ids, which differ series vs movie.
    private static func bestBackdrop(_ artworks: [Artwork]) -> URL? {
        let landscape = artworks.filter { art in
            guard let w = art.width, let h = art.height, h > 0 else { return false }
            return Double(w) / Double(h) >= 1.4
        }
        let best = landscape.max { (($0.width ?? 0) * ($0.height ?? 0)) < (($1.width ?? 0) * ($1.height ?? 0)) }
        guard let image = best?.image, !image.isEmpty else { return nil }
        return Self.imageURL(image)
    }

    /// TheTVDB artwork `image` fields are usually absolute; prefix the CDN host for
    /// the occasional bare path.
    private static func imageURL(_ raw: String) -> URL? {
        if raw.hasPrefix("http") { return URL(string: raw) }
        return URL(string: "https://artworks.thetvdb.com" + (raw.hasPrefix("/") ? raw : "/" + raw))
    }

    // MARK: - Auth

    private func ensureToken() async -> String? {
        if let token { return token }
        guard let key = config.apiKey else { return nil }
        let url = config.apiBaseURL.appendingPathComponent("login")
        let response = await MetadataHTTP.postJSON(LoginResponse.self, url: url, body: ["apikey": key])
        token = response?.data?.token
        return token
    }

    // MARK: - Search

    private func search(query: String, year: Int?, isMovie: Bool,
                        episodeHints: [SeriesEpisodeHint] = [],
                        allowRelogin: Bool) async -> TVDBMetadata? {
        guard let token = await ensureToken(),
              let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else { return nil }
        let type = isMovie ? "movie" : "series"
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/search?query=\(escaped)&type=\(type)") else { return nil }

        let (response, reachable) = await MetadataHTTP.getWithStatus(
            SearchResponse.self, url: url, headers: ["Authorization": "Bearer \(token)"]
        )
        guard let response else {
            // A likely-expired token (unreachable non-404) → drop it and retry once.
            if allowRelogin, !reachable {
                self.token = nil
                return await search(query: query, year: year, isMovie: isMovie,
                                    episodeHints: episodeHints, allowRelogin: false)
            }
            return nil
        }
        let results = response.data ?? []
        guard !results.isEmpty else { return nil }

        // Drop non-canonical variants the query didn't ask for (a folder named
        // "Sword Art Online" must never resolve to "Sword Art Online: Abridged", the
        // parody). If every result is such a variant, the query genuinely wants one,
        // so keep them.
        let filtered = results.filter { !Self.addsUnrequestedVariant(name: $0.name, query: query) }
        let pool = filtered.isEmpty ? results : filtered

        var chosen: SearchResult?
        // An exact year match is the strongest disambiguator when a year is known.
        if let year, let exact = pool.first(where: { Int($0.year ?? "") == year }) {
            chosen = exact
        }
        // Otherwise, when there's a same-name collision (>1 result) and we have
        // on-disk episode titles, pick the candidate whose episodes match ours —
        // robust even when only one season was downloaded (season count alone
        // can't tell a 1-season namesake from S1 of a long-running show).
        if chosen == nil, !isMovie, pool.count > 1, !episodeHints.isEmpty,
           let matched = await disambiguateByEpisodes(pool, hints: episodeHints, query: query, token: token) {
            chosen = matched
        }
        // Prefer a result whose name EXACTLY matches the query over TheTVDB's raw
        // relevance order. Without this, a spinoff query ("The Witcher: Blood
        // Origin") whose year is unknown falls back to relevance and picks the more
        // popular PARENT ("The Witcher"), inheriting its id/art. An exact
        // (normalized) title hit is a far stronger signal than relevance rank.
        if chosen == nil {
            let q = Self.normalizedTitleKey(query)
            if !q.isEmpty { chosen = pool.first(where: { Self.normalizedTitleKey($0.name ?? "") == q }) }
        }
        // Fallback: TheTVDB's own relevance order.
        if chosen == nil { chosen = pool.first }
        guard let chosen else { return nil }
        // Prefer the English name/overview when the base record is another language
        // (TheTVDB serves the primary-language text for many anime — Japanese for
        // Death Note / One Piece / "…Slime").
        return await preferEnglish(chosen.asMetadata(), query: query, isMovie: isMovie, token: token)
    }

    /// Overlay the official English name/overview onto a metadata whose base text is
    /// another language. Fetches the `/translations/eng` record when the base text is
    /// non-Latin script (Japanese/…) OR the resolved title doesn't RESEMBLE what we
    /// searched for — the sign TheTVDB served a foreign primary name in a Latin
    /// script too ("The Eternaut" folder → primary "El eternauta"). English shows,
    /// whose resolved title matches the query, cost no extra request.
    private func preferEnglish(_ meta: TVDBMetadata, query: String, isMovie: Bool, token: String) async -> TVDBMetadata {
        guard let id = meta.tvdbID, !id.isEmpty else { return meta }
        let titleForeign = Self.isNonLatinText(meta.title) || !Self.titleResembles(meta.title, query)
        let overviewForeign = Self.isNonLatinText(meta.overview)
        guard titleForeign || overviewForeign else { return meta }
        let type = isMovie ? "movies" : "series"
        guard let t = await translation(type: type, id: id, language: "eng", token: token) else { return meta }
        var m = meta
        if overviewForeign || titleForeign, let o = t.overview?.nonEmpty { m.overview = o }
        if titleForeign, let n = t.name?.nonEmpty { m.title = n }
        return m
    }

    /// Whether a resolved title plausibly refers to the same show we searched for:
    /// normalized-equal, or one a word-prefix of the other ("Avatar" ⊂ "Avatar The
    /// Last Airbender"). A resolved title that resembles the query is trusted as-is;
    /// one that doesn't is likely a foreign primary name to be replaced with English.
    static func titleResembles(_ title: String?, _ query: String) -> Bool {
        guard let title else { return false }
        let a = normalizedTitleKey(title)
        let b = normalizedTitleKey(query)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b + " ") || b.hasPrefix(a + " ")
    }

    /// Non-canonical "variant" markers — a result adding one of these words the
    /// query didn't contain is a parody/recap/compilation, not the real show.
    private static let variantTokens: Set<String> = [
        "abridged", "recap", "parody", "condensed", "compilation", "fandub", "gagdub", "reaction",
    ]

    /// Whether `name` adds a variant marker word (abridged/recap/…) that `query`
    /// didn't ask for — the mark of a parody/recap entry that must not match a plain
    /// show folder.
    static func addsUnrequestedVariant(name: String?, query: String) -> Bool {
        guard let name else { return false }
        let nameTokens = Set(normalizedTitleKey(name).split(separator: " ").map(String.init))
        let queryTokens = Set(normalizedTitleKey(query).split(separator: " ").map(String.init))
        return !nameTokens.subtracting(queryTokens).isDisjoint(with: variantTokens)
    }

    /// Whether `s` contains characters from a non-Latin script (CJK, kana, hangul,
    /// Cyrillic, Hebrew, Arabic) — the signal that TheTVDB served primary-language
    /// (e.g. Japanese) text we should replace with the English translation.
    static func isNonLatinText(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v)      // hiragana / katakana
                || (0x4E00...0x9FFF).contains(v)  // CJK unified
                || (0x3400...0x4DBF).contains(v)  // CJK ext A
                || (0xAC00...0xD7AF).contains(v)  // hangul
                || (0x0400...0x04FF).contains(v)  // cyrillic
                || (0x0590...0x05FF).contains(v)  // hebrew
                || (0x0600...0x06FF).contains(v)  // arabic
            { return true }
        }
        return false
    }

    /// Lowercased, punctuation-folded, whitespace-collapsed title key for an
    /// exact-match comparison ("The Witcher: Blood Origin" == "the witcher blood
    /// origin"). Kept local so it matches the query and candidate names identically.
    static func normalizedTitleKey(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let mapped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: - Episode-title disambiguation

    /// Picks the search candidate whose episode titles best match the on-disk
    /// library. Fetches each candidate's episode list (bounded to the first few
    /// candidates) and scores exact per-`SxxEyy` title matches. Returns the best
    /// candidate only when the match is confident, else `nil` (caller falls back
    /// to relevance order). Never throws.
    private func disambiguateByEpisodes(
        _ results: [SearchResult],
        hints: [SeriesEpisodeHint],
        query: String,
        token: String
    ) async -> SearchResult? {
        var best: (result: SearchResult, score: Int)?
        var secondBestScore = 0
        // Distinctive-enough acceptance: a clear majority of hints, or (for a
        // tiny hint set) at least two matches. A single generic title ("Pilot")
        // must not decide a collision.
        let strongThreshold = max(2, (hints.count + 1) / 2)

        // Score exact-name matches FIRST, then the rest — a popular show can rank
        // BELOW a foreign namesake in TheTVDB's relevance (Outlander vs the Brazilian
        // "O Caçador", whose English name is also "Outlander"), so a fixed top-N by
        // relevance alone could skip the real show. Bounded to keep the episode
        // fetches modest.
        let q = Self.normalizedTitleKey(query)
        let ordered = results.sorted { a, b in
            let ea = Self.normalizedTitleKey(a.name ?? "") == q
            let eb = Self.normalizedTitleKey(b.name ?? "") == q
            return ea && !eb
        }
        for candidate in ordered.prefix(8) {
            guard let id = candidate.tvdb_id else { continue }
            let names = await episodeNames(seriesID: id, token: token)
            guard !names.isEmpty else { continue }
            var score = 0
            for hint in hints {
                let key = "\(hint.season)x\(hint.episode)"
                if let name = names[key], Self.titlesMatch(name, hint.title) { score += 1 }
            }
            if score > (best?.score ?? 0) {
                secondBestScore = best?.score ?? 0
                best = (candidate, score)
            } else if score > secondBestScore {
                secondBestScore = score
            }
        }

        guard let best else { return nil }
        // Confident when the winner clears the threshold AND beats the runner-up
        // (so a title both namesakes happen to share can't decide it alone).
        if best.score >= strongThreshold, best.score > secondBestScore {
            return best.result
        }
        return nil
    }

    /// `"<season>x<episode>" -> episode name` for a series' first page of episodes
    /// (the default order leads with season 1 — enough to match the seasons a
    /// viewer is most likely to have). Empty on any failure.
    private func episodeNames(seriesID: String, token: String) async -> [String: String] {
        guard let url = URL(string: "\(config.apiBaseURL.absoluteString)/series/\(seriesID)/episodes/default?page=0") else { return [:] }
        let (response, _) = await MetadataHTTP.getWithStatus(
            EpisodesResponse.self, url: url, headers: ["Authorization": "Bearer \(token)"]
        )
        guard let episodes = response?.data?.episodes else { return [:] }
        var map: [String: String] = [:]
        for ep in episodes {
            guard let s = ep.seasonNumber, let n = ep.number,
                  let name = ep.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { continue }
            map["\(s)x\(n)"] = name
        }
        return map
    }

    /// Two episode titles match when their alphanumeric token sets are equal or
    /// one contains the other — tolerant of scene/quality remnants the local
    /// parser may leave and of minor punctuation/casing differences. A bare
    /// numeric-only overlap never matches.
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        if ta == tb { return true }
        return ta.isSubset(of: tb) || tb.isSubset(of: ta)
    }

    private static func tokens(_ s: String) -> Set<String> {
        // Broken into typed locals so this chain type-checks fast (measured ~178ms
        // as a single expression). Same transform: lowercase, non-alphanumerics →
        // spaces, split, drop short tokens and pure-number tokens.
        let mapped: [Character] = s.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        let cleaned: String = mapped.reduce(into: "") { $0.append($1) }
        let words: [String] = cleaned.split(separator: " ").map(String.init)
        let kept: [String] = words.filter { $0.count >= 2 && Int($0) == nil }
        return Set(kept)
    }

    // MARK: - DTOs

    private struct LoginResponse: Decodable {
        let data: TokenData?
        struct TokenData: Decodable { let token: String? }
    }

    private struct ExtendedResponse: Decodable {
        let data: DataField?
        struct DataField: Decodable { let artworks: [Artwork]? }
    }

    /// TheTVDB v4 `/series|movies/{id}/extended` payload — the rich record we read
    /// when resolving directly by a known id (name/overview/year/poster/genres/ids).
    private struct SeriesExtendedResponse: Decodable {
        let data: SeriesExtended?
    }

    private struct SeriesExtended: Decodable {
        let id: Int?
        let name: String?
        let overview: String?
        let year: String?
        let image: String?
        let genres: [Genre]?
        let remoteIds: [RemoteID]?
        /// A bare `yyyy-MM-dd` calendar day for the next scheduled episode (no time).
        let nextAired: String?
        /// The work's original language (`eng`, `jpn`, …).
        let originalLanguage: String?
        struct Genre: Decodable { let name: String? }
        struct RemoteID: Decodable { let id: String?; let sourceName: String? }
    }

    /// TheTVDB v4 `/{type}/{id}/translations/{language}` payload — a single
    /// language's localized name + overview.
    private struct TranslationResponse: Decodable {
        let data: Translation?
        struct Translation: Decodable {
            let name: String?
            let overview: String?
            let language: String?
        }
    }

    private struct Artwork: Decodable {
        let image: String?
        let width: Int?
        let height: Int?
        let type: Int?
    }

    private struct SearchResponse: Decodable {
        let data: [SearchResult]?
    }

    /// TheTVDB v4 `/series/{id}/episodes/{seasonType}` payload (first page).
    private struct EpisodesResponse: Decodable {
        let data: DataField?
        struct DataField: Decodable { let episodes: [Episode]? }
        struct Episode: Decodable {
            let number: Int?
            let seasonNumber: Int?
            let name: String?
            /// `yyyy-MM-dd` air day, matched against the series' `nextAired`.
            let aired: String?
        }
    }

    private struct SearchResult: Decodable {
        let tvdb_id: String?
        let name: String?
        let overview: String?
        let image_url: String?
        let year: String?
        let genres: [String]?
        let remote_ids: [RemoteID]?
        /// TheTVDB search hit's original language code (`eng`, `jpn`, …).
        let primary_language: String?

        struct RemoteID: Decodable {
            let id: String?
            let sourceName: String?
        }

        func asMetadata() -> TVDBMetadata {
            var imdb: String?
            var tmdb: String?
            for remote in remote_ids ?? [] {
                guard let source = remote.sourceName?.lowercased(), let id = remote.id, !id.isEmpty else { continue }
                if source.contains("imdb") { imdb = id }
                else if source.contains("themoviedb") || source == "tmdb" { tmdb = id }
            }
            return TVDBMetadata(
                tvdbID: tvdb_id,
                imdbID: imdb,
                tmdbID: tmdb,
                overview: overview?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                posterURL: image_url.flatMap { URL(string: $0) },
                genres: genres ?? [],
                year: year.flatMap { Int($0) },
                title: name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                originalLanguage: primary_language?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            )
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+")
        return set
    }()
}
