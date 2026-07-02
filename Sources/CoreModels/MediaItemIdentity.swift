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
