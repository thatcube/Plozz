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
    ///    year are almost certainly the same release; two *series* with the same
    ///    name routinely are not (original vs reboot, anime vs live-action), and
    ///    a wrong year on one server would silently collapse them. Series must
    ///    rely on external ids alone.
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
                result.append(.external(source: entry.canonical, value: value.lowercased()))
            }
        }

        if result.isEmpty, let titleIdentity = titleIdentity(for: item) {
            result.append(titleIdentity)
        }
        return result
    }

    private static func titleIdentity(for item: MediaItem) -> MediaIdentity? {
        guard item.kind == .movie else { return nil }
        guard let year = item.productionYear else { return nil }
        let normalized = normalizedTitle(item.title)
        guard !normalized.isEmpty else { return nil }
        return .title(normalizedTitle: normalized, year: year, kind: item.kind)
    }

    /// Whether two movies almost certainly refer to **different works** despite
    /// sharing a merge key — the positive-contradiction signal the cross-server
    /// split-guard ejects on. Shared by both the full-item merger
    /// (``MediaItemMerger/refineComponent(_:)``) and the identity index's
    /// membership walk (``IdentityIndex``), which stores only a title/year per
    /// source, so a bad shared external id (one server tagging Scream 7 with
    /// Scream 6's TMDb id) is split back apart identically everywhere a title
    /// resolves its cross-server set — Home cards, the detail version picker,
    /// best-source playback, and the watch fan-out.
    ///
    /// Only applies when **both** sides are movies (`kindA`/`kindB` == `.movie`);
    /// series/episodes rely on their own kind rules and never contradict here.
    /// With both titles present and normalized, the decision is:
    ///
    /// - **Identical titles** → never contradict. This is deliberately
    ///   conservative: a same-title remake sharing a bad id (rare) stays merged
    ///   rather than risk false-splitting one film whose year merely slips between
    ///   servers' metadata.
    /// - **Prefix-compatible but not identical** (a base title vs an edition/year
    ///   suffix — "Dune" vs "Dune 2021" — OR a base title vs a numbered sequel —
    ///   "Scream" vs "Scream 6") → contradict **only** when both years are present
    ///   and differ by more than one. A clear year conflict distinguishes the
    ///   base-vs-sequel false merge from a same-film edition suffix; without two
    ///   corroborating-or-conflicting years we keep them merged (edition case).
    /// - **Fully different titles** (neither equal nor a prefix — a localized title
    ///   or a genuinely different film) → contradict **unless** the years
    ///   corroborate (both present within one year). A matching year rescues a
    ///   localized twin; a missing or conflicting year lets the title clash stand,
    ///   which is what splits "Scream 6" (2023) from a sparsely-scraped, yearless
    ///   "Scream 7" that a server mis-tagged with the same id.
    ///
    /// Absent title signal (either normalized title empty) never contradicts, so a
    /// title-less sparse row is always merged, never split. Titles may be raw or
    /// already normalized — normalization is idempotent.
    public static func titlesPlausiblyContradict(
        titleA: String,
        yearA: Int?,
        kindA: MediaItemKind,
        titleB: String,
        yearB: Int?,
        kindB: MediaItemKind
    ) -> Bool {
        guard kindA == .movie, kindB == .movie else { return false }
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
