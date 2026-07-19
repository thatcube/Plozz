import Foundation

/// A stable, provider-agnostic identity for a media item, used to recognise when
/// the *same* title shows up on more than one server (e.g. a movie that lives on
/// both a Jellyfin and a Plex account).
///
/// Two flavours, in priority order:
/// - `.external` — a shared strong external id (IMDb, TMDb, TVDb). The most
///   reliable signal because both servers reference the same catalogue entry.
/// - `.title` — the normalized title + release year + media kind, the fallback
///   used only when no external id is present (and only for movies — see the
///   safety rules on ``MediaItemIdentity/identities(for:)``).
///
/// This was lifted out of `FeatureSearch.SearchDeduplicator` so that Home, Search
/// and any future surface share **one** well-tested identity definition instead
/// of duplicating the rules (and their subtle safety carve-outs).
public enum MediaIdentity: Hashable, Sendable, Codable {
    case external(source: String, value: String)
    case title(normalizedTitle: String, year: Int?, kind: MediaItemKind)
    /// Same raw item ID on the **same physical server** — catches duplicates from
    /// one server seen through two different user accounts (a server-global item
    /// id returned by both). Deliberately **not** emitted by
    /// ``MediaItemIdentity/identities(for:)`` (a bare item id collides across
    /// servers — Plex `ratingKey`s are small per-server integers); the
    /// same-server dedup that needs it is applied inside ``MediaItemMerger`` where
    /// the physical server id is known. The case is retained for
    /// ``FanoutDiagnostics`` / persisted-snapshot backward compatibility.
    case sameItemID(String)
}

/// Pure, provider-agnostic identity resolution shared by every cross-server
/// surface (Home rows, aggregated Library browse, Search).
///
/// The rules here are deliberately conservative — collapsing two genuinely
/// different titles into one card is a far worse failure than missing a merge —
/// so the safety carve-outs are encoded once, here, and exhaustively tested.
public enum MediaItemIdentity {
    /// External id namespaces that uniquely identify a catalogue entry across
    /// providers, in match-priority order, each paired with the canonical token
    /// used as its merge key.
    ///
    /// Resolution goes through ``ProviderIDNamespace`` so every backend spelling
    /// of a key collapses to one identity: `IMDb`/`imdb`, `Tmdb`/`tmdbid`,
    /// `Tvdb`/`TheTvdb`, `AniList`/`anilistid`, `myanimelist`/`mal`, `anidb`, …
    /// Anime namespaces are included so anime series — which frequently carry
    /// **only** an AniList/MAL/AniDB/TVmaze id and no IMDb/TMDb/TVDb — still merge
    /// across servers. Cross-kind false merges are impossible: an identity is only
    /// a merge key *within one media kind* (see ``MediaItemMerger/merge(_:serverInfo:identitySources:)``),
    /// and each of these ids is unique per work within its kind.
    public static let strongExternalNamespaces: [(namespace: ProviderIDNamespace, canonical: String)] = [
        (.imdb, "imdb"),
        (.tmdb, "tmdb"),
        (.tvdb, "tvdb"),
        (.tvmaze, "tvmaze"),
        (.aniList, "anilist"),
        (.myAnimeList, "myanimelist"),
        (.aniDB, "anidb")
    ]

    /// The canonical strong-external tokens (back-compat / diagnostics).
    public static let strongExternalSources = strongExternalNamespaces.map(\.canonical)

    /// The candidate identities for an item, strongest first. Two items are the
    /// same title when *any* of their identities match.
    ///
    /// ## Safety rules (do not relax without new tests)
    /// 1. **External ids win and suppress the title key.** An item with a strong
    ///    external id has a well-defined catalogue identity; adding a title key on
    ///    top risks bridging two completely different shows that merely share a
    ///    name/year via a false transitive merge (anime vs live-action remake with
    ///    bad year metadata).
    /// 2. **Title identity is movies-only.** Two films with the same title and
    ///    year are almost certainly the same release; episodes and whole series
    ///    require external IDs. Episodes may additionally use explicit `Series*`
    ///    IDs scoped by exact season/episode numbers.
    /// 3. **No bare `.sameItemID`.** A raw item id is only unique *within one
    ///    server* — Plex `ratingKey`s are small per-server integers that collide
    ///    across unrelated servers, so emitting `.sameItemID(item.id)` here would
    ///    false-merge two different titles that happen to share a ratingKey. The
    ///    same-server / two-account dedup that a bare id enables is applied inside
    ///    ``MediaItemMerger`` instead, where the *physical server id* is known and
    ///    the collision can't happen.
    public static func identities(for item: MediaItem) -> [MediaIdentity] {
        var result: [MediaIdentity] = []

        // Alias- and punctuation-insensitive resolution (`providerID(_:)`) so a
        // backend that spells a key `TheTvdb`, `TMDb ID` or `myanimelist` still
        // matches — the old plain-`.lowercased()` compare missed those.
        for entry in strongExternalNamespaces {
            if let value = item.providerIDs.providerID(entry.namespace) {
                guard let source = externalSource(
                    entry.canonical,
                    for: item
                ) else { continue }
                result.append(.external(source: source, value: value.lowercased()))
            }
        }

        // Plex's global metadata guid (`plex://<type>/<globalid>`) is a strong,
        // server-INDEPENDENT identity: the same across every server/account that
        // matched the title, and the key the account-level Watchlist is addressed
        // by. Emitting it lets items that carry *only* a PlexGuid — notably
        // Watchlist rows, whose Discover fetch omits the external `Guid` array —
        // merge across accounts/servers instead of leaving two cards with the same
        // global item id, which SwiftUI renders as a ghost/empty gap in the row.
        // Safe (unlike a bare per-server ratingKey): the guid is globally unique
        // per work and self-scopes by kind (`plex://movie/…` vs `plex://show/…`),
        // and the merge split-guard still ejects any genuinely contradictory pair.
        if let plexGuid = item.providerIDs["PlexGuid"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plexGuid.isEmpty {
            if let source = externalSource("plexguid", for: item) {
                result.append(.external(source: source, value: plexGuid.lowercased()))
            }
        }

        result.append(contentsOf: seriesEpisodeIdentities(for: item))

        if result.isEmpty, let titleIdentity = titleIdentity(for: item) {
            result.append(titleIdentity)
        }
        return result
    }

    /// Episodes are scoped by `(season, episode)` even when an external ID exists.
    /// Plex and metadata-enriched filesystem shares can expose the SHOW's IDs on
    /// every episode; treating those raw IDs as episode identities collapses an
    /// entire series into one cross-server source set. Scoping also remains safe
    /// when the backend really supplied episode-level IDs.
    private static func externalSource(
        _ canonical: String,
        for item: MediaItem
    ) -> String? {
        guard item.kind == .episode else { return canonical }
        guard let season = item.seasonNumber,
              let episode = item.episodeNumber else { return nil }
        return "\(canonical):s\(season)e\(episode)"
    }

    private static func titleIdentity(for item: MediaItem) -> MediaIdentity? {
        guard item.kind == .movie else { return nil }
        guard let year = item.productionYear else { return nil }
        let normalized = normalizedTitle(item.title)
        guard !normalized.isEmpty else { return nil }
        return .title(normalizedTitle: normalized, year: year, kind: item.kind)
    }

    /// The strong SHOW-level external id namespaces an episode can carry, paired
    /// with the canonical token. Shared by ``seriesEpisodeIdentities(for:)`` (which
    /// forms the episode's merge keys) and ``seriesExternalIDs(for:)`` (which the
    /// episode split-guard compares), so the two stay in lock-step.
    private static let seriesExternalNamespaces: [(namespace: ProviderIDNamespace, canonical: String)] = [
        (.seriesImdb, "imdb"),
        (.seriesTmdb, "tmdb"),
        (.seriesTvdb, "tvdb"),
        (.seriesTvmaze, "tvmaze"),
        (.seriesAniList, "anilist"),
        (.seriesMal, "myanimelist"),
        (.seriesAniDB, "anidb")
    ]

    private static func seriesEpisodeIdentities(
        for item: MediaItem
    ) -> [MediaIdentity] {
        guard item.kind == .episode,
              let season = item.seasonNumber,
              let episode = item.episodeNumber else { return [] }
        return seriesExternalNamespaces.compactMap { namespace, canonical in
            guard let value = item.providerIDs.providerID(namespace) else {
                return nil
            }
            return .external(
                source: "series-\(canonical):s\(season)e\(episode)",
                value: value.lowercased()
            )
        }
    }

    /// An episode's SHOW-level external ids as `canonical namespace → lowercased
    /// value` (e.g. `["tvdb": "81797"]`). This is the show identity the episode
    /// split-guard compares — a conflicting value in a shared namespace proves two
    /// episodes belong to *different shows* even when a bad shared id merged them.
    public static func seriesExternalIDs(for item: MediaItem) -> [String: String] {
        var result: [String: String] = [:]
        for entry in seriesExternalNamespaces {
            if let value = item.providerIDs.providerID(entry.namespace) {
                result[entry.canonical] = value.lowercased()
            }
        }
        return result
    }

    /// Whether two **episodes** almost certainly belong to *different works* despite
    /// sharing a merge key — the episode arm of the split-guard. One server
    /// mis-tagging show Y's SxEy with show X's series id (a documented Plex/NFO
    /// failure mode — see ``externalSource(_:for:)``) makes both share the same
    /// `series-<ns>:sXeY` key and false-merge into one card, cross-linking their
    /// sources so best-source playback / the version picker / the watch fan-out can
    /// target the *wrong show's* episode.
    ///
    /// The signal is deliberately keyed on **show identity + season/episode
    /// numbering**, never the per-episode title: a legitimate cross-server twin can
    /// carry a localized or differently-scraped episode title, so a title compare
    /// would false-split real duplicates. Two episodes positively contradict when:
    /// - both season numbers are present and differ, or both episode numbers are
    ///   present and differ (a different slot in the run), or
    /// - a **series** external id shared by namespace disagrees in value (proof they
    ///   are different shows riding one bad id).
    ///
    /// Absent signal never contradicts (no S/E, or no overlapping series id), so a
    /// sparse twin — or two copies that merged on an episode-level id and expose no
    /// series ids — always stays merged, matching the movie/series guards' "a false
    /// merge is worse than a missed split" stance.
    ///
    /// Intended limitation: if two genuinely different shows overlap in ONLY the
    /// single mis-tagged namespace (they share the one bad id and expose no OTHER
    /// distinguishing series id, with matching/absent S/E), this returns false and
    /// the false merge persists — there is no positive evidence to split on. This is
    /// the deliberate "never split on absent/insufficient signal" tradeoff: a false
    /// split of a legitimate cross-server twin is worse than this residual, and any
    /// second, correct shared series id (or a differing S/E) immediately splits them.
    public static func episodesPlausiblyContradict(
        seasonA: Int?, episodeA: Int?, seriesIDsA: [String: String],
        seasonB: Int?, episodeB: Int?, seriesIDsB: [String: String]
    ) -> Bool {
        if let sa = seasonA, let sb = seasonB, sa != sb { return true }
        if let ea = episodeA, let eb = episodeB, ea != eb { return true }
        for (namespace, valueA) in seriesIDsA {
            if let valueB = seriesIDsB[namespace], valueA != valueB { return true }
        }
        return false
    }

    /// Whether two items almost certainly refer to **different works** despite
    /// sharing a merge key — the positive-contradiction signal the cross-server
    /// split-guard ejects on. Shared by both the full-item merger
    /// (``MediaItemMerger/refineComponent(_:)``) and the identity index's
    /// membership walk (``IdentityIndex``), which stores only a title/year per
    /// source, so a bad shared external id is split back apart identically
    /// everywhere a title resolves its cross-server set — Home cards, Search, the
    /// detail server/version picker, best-source playback, and the watch fan-out.
    ///
    /// Only same-kind **movie/movie** or **series/series** pairs can contradict;
    /// episodes and cross-kind pairs never do (episodes aren't merged through this
    /// path, and TMDb/TVDb reuse one integer id space across kinds but the merge is
    /// already kind-scoped). The two kinds decide differently because a series
    /// title carries far less signal than a movie's:
    ///
    /// **Series** — a series title is identical across the same show and unreliable
    /// across localizations, so the *only* confident contradiction is a **large
    /// production-year gap** (both years present, ≥ ``largeProductionYearGap``
    /// apart): an in-place remake/reboot or, crucially, an anime vs its much later
    /// live-action adaptation ("One Piece" anime 1999 vs live-action 2023, bridged
    /// by a server emitting one TVDb id for both). A legitimate same-show copy on
    /// two servers shares the same debut year (gap 0), so this never false-splits a
    /// real twin; without two years present we never split.
    ///
    /// **Movies** — with both titles present and normalized, the decision is:
    /// - **Identical titles** → never contradict. Deliberately conservative: a
    ///   same-title remake sharing a bad id (rare) stays merged rather than risk
    ///   false-splitting one film whose year merely slips between servers.
    /// - **Prefix-compatible but not identical** ("Dune" vs "Dune 2021", "Scream"
    ///   vs "Scream 6") → contradict **only** on a hard year conflict (> 1yr): that
    ///   distinguishes the base-vs-sequel false merge from a same-film edition
    ///   suffix; otherwise keep merged.
    /// - **Fully different titles** (a localized title or a genuinely different
    ///   film) → contradict **unless** the years corroborate (both present within
    ///   one year). A matching year rescues a localized twin; a missing or
    ///   conflicting year lets the clash split them ("Scream 6" 2023 vs a yearless,
    ///   mis-tagged "Scream 7").
    ///
    /// Absent signal never contradicts (a series with < 2 years; a movie with an
    /// empty normalized title), so sparse rows always stay merged. Titles/years may
    /// be raw; title normalization is idempotent.
    public static func titlesPlausiblyContradict(
        titleA: String,
        yearA: Int?,
        kindA: MediaItemKind,
        titleB: String,
        yearB: Int?,
        kindB: MediaItemKind
    ) -> Bool {
        guard kindA == kindB, kindA == .movie || kindA == .series else { return false }

        if kindA == .series {
            // Series: title is no signal (identical across the same show, differently
            // spelled across localizations), so only a large production-year gap can
            // contradict. Same-show twins share a debut year, so this never splits
            // them; a missing year on either side leaves the pair merged.
            guard let ya = yearA, let yb = yearB else { return false }
            return abs(ya - yb) >= largeProductionYearGap
        }

        // Movies: title-structure decision (unchanged from the Scream 6/7 design).
        let a = normalizedTitle(titleA)
        let b = normalizedTitle(titleB)
        guard !a.isEmpty, !b.isEmpty else { return false }

        let yearsCorroborate: Bool
        let yearsConflict: Bool
        if let ya = yearA, let yb = yearB {
            let gap = abs(ya - yb)
            yearsCorroborate = gap <= 1
            yearsConflict = gap > 1
        } else {
            yearsCorroborate = false
            yearsConflict = false
        }

        if a == b { return false }
        if normalizedTitlesCompatible(a, b) {
            // Prefix (edition suffix vs base-vs-sequel): only a hard year conflict
            // proves a different work; otherwise treat as the same film's variant.
            return yearsConflict
        }
        // Fully different titles: a corroborating year rescues a localized twin;
        // anything else (conflict or a missing year) lets the clash split them.
        return !yearsCorroborate
    }

    /// The production-year gap (in years) at or beyond which two same-kind **series**
    /// sharing a merge key are treated as **different works** — a remake/reboot or
    /// an anime vs its later live-action adaptation. Chosen well above any plausible
    /// cross-server metadata slip for a single show (a debut year is well-defined
    /// and both servers scrape it, so 0–1yr, at most 2), so it never false-splits a
    /// legitimate twin, while comfortably catching real remakes/adaptations
    /// (essentially always ≥ 10yr apart).
    static let largeProductionYearGap = 5

    /// Normalized titles are compatible when identical or one is a word-boundary
    /// prefix of the other ("dune" vs "dune 2021"), so subtitle/year suffixes
    /// don't read as a clash while a differing trailing token ("scream 6" vs
    /// "scream 7") does. Inputs are assumed already ``normalizedTitle(_:)``-folded.
    public static func normalizedTitlesCompatible(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return a.hasPrefix(b + " ") || b.hasPrefix(a + " ")
    }

    /// Canonical title form: lower-cased, accent-folded, punctuation removed and
    /// internal whitespace collapsed so "Spider-Man" and "spider man" match.
    public static func normalizedTitle(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
