import Foundation

/// One server's copy that a watch-state mutation must converge — the minimal,
/// **persistable** addressing a ``WatchStateReconciler`` needs to write to a
/// server long after the originating screen/player is gone. A flattened subset of
/// ``MediaSourceRef`` (no versions / display fields) so the outbox file stays small
/// and stable across app versions.
public struct WatchMutationTarget: Codable, Hashable, Sendable {
    /// The owning `Account.id`.
    public var accountID: String
    /// This server's local id for the title (Jellyfin item id / Plex ratingKey).
    public var itemID: String
    /// The backend kind, for diagnostics / future per-backend routing. Optional
    /// because not every enqueue site knows it.
    public var providerKind: ProviderKind?

    public init(accountID: String, itemID: String, providerKind: ProviderKind? = nil) {
        self.accountID = accountID
        self.itemID = itemID
        self.providerKind = providerKind
    }

    /// Stable identity for de-duplicating targets within a mutation.
    public var id: String { "\(accountID):\(itemID)" }
}

/// The origin server's address for an episode mutation — the seed a
/// ``WatchStateReconciler`` uses to (re)discover the episode's series identity and
/// fan the watch out to the **same** episode on every other server hosting the
/// series. Persisted independently of ``WatchMutation/targets`` so a retry can
/// still resolve twins *after* the origin target has already been written and
/// removed from the queue.
public struct EpisodeOrigin: Codable, Hashable, Sendable {
    /// The origin `Account.id` the episode played from.
    public var accountID: String
    /// That server's own id for the played episode.
    public var itemID: String

    public init(accountID: String, itemID: String) {
        self.accountID = accountID
        self.itemID = itemID
    }
}

/// A durable, self-contained description of a Trakt scrobble to perform — kept
/// neutral (no `TraktService` types) so it can live in the outbox file and be
/// replayed at launch by whatever scrobbler the app wires in.
public struct TraktScrobbleIntent: Codable, Hashable, Sendable {
    public var kind: MediaItemKind
    public var title: String?
    /// Series title for episodes, so anime trackers can title-search brand-new
    /// shows that public id maps (ARM) haven't indexed yet. Nil for movies.
    public var seriesTitle: String?
    public var year: Int?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    /// External ids (imdb/tmdb/tvdb/trakt, mixed casing tolerated downstream).
    public var providerIDs: [String: String]
    /// Watched percent at the scrobble (0...100).
    public var progress: Double

    public init(
        kind: MediaItemKind,
        title: String?,
        seriesTitle: String? = nil,
        year: Int?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        providerIDs: [String: String],
        progress: Double
    ) {
        self.kind = kind
        self.title = title
        self.seriesTitle = seriesTitle
        self.year = year
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.providerIDs = providerIDs
        self.progress = progress
    }
}

/// A single watch-state INTENT, persisted to disk **before** the network call so a
/// watch is never silently lost when a server is asleep / the app is offline / the
/// app is killed mid-write.
///
/// One mutation expresses the desired convergent state for *one title* across the
/// servers that hold it (`targets`): an optional resume position to write and/or an
/// optional played flag, plus an optional one-shot Trakt mirror. The reconciler
/// drains it best-effort and idempotently — applying it twice is harmless.
public struct WatchMutation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// When the user's action actually happened (NOT when it is sent). The basis
    /// for stale-write suppression: a queued write older than what has already been
    /// accepted for this title is dropped so a late offline write can't rewind state.
    public var capturedAt: Date
    /// Cross-server canonical id (`trakt:`/`imdb:`/`tmdb:`/`tvdb:` …) used to coalesce
    /// and order mutations for the same title across servers and relaunches.
    public var canonicalMediaID: String
    public var seasonNumber: Int?
    public var episodeNumber: Int?

    /// Desired resume position (seconds) to converge on every target, or `nil` to
    /// leave resume untouched.
    public var resumePosition: TimeInterval?
    /// Desired played flag to converge on every target, or `nil` to leave it.
    public var played: Bool?
    /// When `true`, finishing also clears the resume point everywhere (a finished
    /// title shouldn't keep a stale resume on any server).
    public var clearResume: Bool

    /// Servers still needing this write. The reconciler removes a target as it
    /// succeeds, so a partial fan-out resumes exactly where it left off.
    public var targets: [WatchMutationTarget]
    /// Optional durable Trakt mirror, drained once (idempotency-keyed).
    public var trakt: TraktScrobbleIntent?
    /// Whether the Trakt mirror still needs writing (cleared on success).
    public var traktPending: Bool
    /// Whether the Simkl mirror still needs writing (cleared on success).
    public var simklPending: Bool
    /// Whether the AniList mirror still needs writing (cleared on success).
    public var anilistPending: Bool
    /// Whether the MAL mirror still needs writing (cleared on success).
    public var malPending: Bool
    /// Retry counter for backoff / give-up diagnostics.
    public var attempts: Int

    /// For an **episode** mutation, the origin server's episode address, used to
    /// resolve the series identity and expand ``targets`` to the same episode on
    /// every other server hosting the series. `nil` for movies and for episode
    /// mutations enqueued before this capability existed.
    public var episodeOrigin: EpisodeOrigin?
    /// Whether cross-server **twin targets** still need resolving for this episode.
    /// Set when an episode mutation is created; cleared once a drain conclusively
    /// expands the targets (every other server probed, none left inconclusive).
    /// While `true` the mutation is never considered fully applied, so a drain that
    /// couldn't reach an asleep twin server retries later. Always `false` for
    /// non-episode mutations, so movie / single-target convergence is unaffected.
    public var expansionPending: Bool

    /// The played title's cross-server ``MediaIdentity`` set, persisted so a drain
    /// can re-resolve the **identity index**'s full server set for the title — even
    /// after relaunch — and fan a movie / series watch out to every server as the
    /// eager index warms (the index is built progressively at launch, so a title
    /// stopped before it finished must pick up the rest later). Empty for items
    /// with no strong identity (they can't index-match) and for mutations enqueued
    /// before this field existed. Reuses ``expansionPending`` as its keep-alive
    /// gate; the applier branches on `episodeOrigin != nil` (episode twins) vs
    /// these identities (movie / series index union).
    public var identities: [MediaIdentity]

    /// The played title's media **kind** (movie / series), persisted so the
    /// identity fan-out at drain time can scope the eager index lookup to the same
    /// kind. TMDb/TVDb reuse one integer id space across movies and series
    /// (movie 550 ≠ tv 550), so an unscoped union could fan a movie's watched-write
    /// out to a *series* on another server that merely shares the id. `nil` for
    /// mutations enqueued before this field existed — treated as "don't scope" so a
    /// legacy queued write keeps its prior (unscoped) behaviour rather than
    /// silently fanning out to nothing.
    public var kind: MediaItemKind?

    /// The played title's ``MediaItemIdentity/normalizedTitle(_:)`` + production
    /// year, persisted so the drain-time identity fan-out can split a bad shared
    /// external id apart (one server tagging two different movies with the same
    /// TMDb/IMDb id). Without an anchor the index union would fan a Scream 7 watch
    /// out to a mis-tagged Scream 6 on another server. `nil` for episodes, for
    /// titleless items, and for mutations enqueued before these fields existed —
    /// treated as "no title signal" so the union stays unguarded (prior behaviour)
    /// rather than dropping a queued write.
    public var anchorTitle: String?
    public var anchorYear: Int?

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        canonicalMediaID: String,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        resumePosition: TimeInterval? = nil,
        played: Bool? = nil,
        clearResume: Bool = false,
        targets: [WatchMutationTarget],
        trakt: TraktScrobbleIntent? = nil,
        attempts: Int = 0,
        episodeOrigin: EpisodeOrigin? = nil,
        expansionPending: Bool = false,
        identities: [MediaIdentity] = [],
        kind: MediaItemKind? = nil,
        anchorTitle: String? = nil,
        anchorYear: Int? = nil,
        simklPending: Bool? = nil,
        anilistPending: Bool? = nil,
        malPending: Bool? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.canonicalMediaID = canonicalMediaID
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.resumePosition = resumePosition
        self.played = played
        self.clearResume = clearResume
        self.targets = targets
        self.trakt = trakt
        self.traktPending = trakt != nil
        self.simklPending = simklPending ?? (trakt != nil)
        self.anilistPending = anilistPending ?? (trakt != nil)
        self.malPending = malPending ?? (trakt != nil)
        self.attempts = attempts
        self.episodeOrigin = episodeOrigin
        self.expansionPending = expansionPending
        self.identities = identities
        self.kind = kind
        self.anchorTitle = anchorTitle
        self.anchorYear = anchorYear
    }

    // MARK: - Codable (back-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, canonicalMediaID, seasonNumber, episodeNumber
        case resumePosition, played, clearResume, targets, trakt, traktPending
        case simklPending, anilistPending, malPending
        case attempts, episodeOrigin, expansionPending, identities, kind
        case anchorTitle, anchorYear
    }

    /// Decodes tolerating outbox files written before `episodeOrigin` /
    /// `expansionPending` / `identities` / `kind` / `anchorTitle` / `anchorYear` /
    /// tracker pending flags existed (they decode to `nil` / `false` / `[]`), so an
    /// in-app upgrade never drops a queued watch. `encode(to:)` is synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        canonicalMediaID = try container.decode(String.self, forKey: .canonicalMediaID)
        seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try container.decodeIfPresent(Int.self, forKey: .episodeNumber)
        resumePosition = try container.decodeIfPresent(TimeInterval.self, forKey: .resumePosition)
        played = try container.decodeIfPresent(Bool.self, forKey: .played)
        clearResume = try container.decodeIfPresent(Bool.self, forKey: .clearResume) ?? false
        targets = try container.decodeIfPresent([WatchMutationTarget].self, forKey: .targets) ?? []
        trakt = try container.decodeIfPresent(TraktScrobbleIntent.self, forKey: .trakt)
        traktPending = try container.decodeIfPresent(Bool.self, forKey: .traktPending) ?? (trakt != nil)
        simklPending = try container.decodeIfPresent(Bool.self, forKey: .simklPending) ?? false
        anilistPending = try container.decodeIfPresent(Bool.self, forKey: .anilistPending) ?? false
        malPending = try container.decodeIfPresent(Bool.self, forKey: .malPending) ?? false
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        episodeOrigin = try container.decodeIfPresent(EpisodeOrigin.self, forKey: .episodeOrigin)
        expansionPending = try container.decodeIfPresent(Bool.self, forKey: .expansionPending) ?? false
        identities = try container.decodeIfPresent([MediaIdentity].self, forKey: .identities) ?? []
        kind = try container.decodeIfPresent(MediaItemKind.self, forKey: .kind)
        anchorTitle = try container.decodeIfPresent(String.self, forKey: .anchorTitle)
        anchorYear = try container.decodeIfPresent(Int.self, forKey: .anchorYear)
    }

    /// Title-level key used to COALESCE queued mutations (latest wins, targets
    /// unioned) and to key the stale-write clock. Excludes the account/day so any
    /// server's write for the same title/episode collapses to one queue entry.
    ///
    /// Scoped by media **kind**: TMDb/TVDb reuse one integer id space across movies
    /// and series (movie 550 ≠ tv 550), so an unscoped key would collapse a movie's
    /// and a series' write into one entry and cross-apply watched state — the same
    /// kind scoping the merger applies (``KindScopedIdentity``). A legacy mutation
    /// with no persisted `kind` uses a stable `?` token so it keeps coalescing with
    /// its own kind rather than silently splitting mid-flight.
    public var coalesceKey: String {
        "\(kind?.rawValue ?? "?")|\(canonicalMediaID)|s\(seasonNumber.map(String.init) ?? "-")|e\(episodeNumber.map(String.init) ?? "-")"
    }

    /// Durable Trakt idempotency key (`profile | canonicalMediaId | episode |
    /// day_bucket`) so our own replays across relaunch don't double-write history.
    /// `profile` is folded in by the reconciler (its store is profile-scoped) so it
    /// is omitted here.
    public func traktIdempotencyKey(dayBucket: String) -> String {
        "\(coalesceKey)|\(dayBucket)"
    }

    /// Whether every server target AND all tracker mirrors are done **and** no
    /// cross-server twin expansion is still owed — safe to prune.
    public var isFullyApplied: Bool {
        targets.isEmpty && !traktPending && !simklPending && !anilistPending && !malPending && !expansionPending
    }

    // MARK: - Canonical id

    /// Derives a stable cross-server canonical id from a provider id map, preferring
    /// the most authoritative namespace. After Trakt (the watch-sync authority, which
    /// is not a merge namespace) this mirrors ``MediaItemIdentity/strongExternalNamespaces``
    /// **exactly** — same order, same alias resolution, same canonical tokens — so the
    /// outbox's notion of "same title across servers" matches the identity index. If
    /// they diverged, a mutation could fail to coalesce or fan out across servers the
    /// merger treats as one title (r6-canonical-weak).
    ///
    /// The **title fallback is kind-scoped** so it never coalesces two titles the
    /// merger would not have united (r8-canonicalid):
    ///  - `.movie` falls back to `title:slug:year` **only when a year is present**,
    ///    mirroring ``MediaItemIdentity/titleIdentity(for:)`` exactly (movies-only,
    ///    year-required). A year-less movie has no title identity in the merger, so a
    ///    bare `title:slug` here would collapse two *different* same-named movies that
    ///    were never merged, cross-applying watched state.
    ///  - `.episode` falls back to a `title:slug(:year)` keyed on the **series (parent)
    ///    title** the caller supplies. This is a deliberate outbox-coalescing behavior
    ///    (NOT a merge-identity mirror): the season/episode numbers on ``coalesceKey``
    ///    disambiguate within the series and the parent title disambiguates across
    ///    series, so the *same* episode reached through two servers with no external
    ///    ids still collapses into one write.
    ///  - Everything else (whole `.series`, `.season`, unknown/`nil` kind) gets **no**
    ///    title fallback — the merger has no title identity for these, so we must not
    ///    invent one. They use the per-item fallback (never coalesces across servers,
    ///    which is correct because they could not have merged across them either).
    public static func canonicalMediaID(
        providerIDs: [String: String],
        title: String? = nil,
        year: Int? = nil,
        kind: MediaItemKind? = nil,
        fallback: String
    ) -> String {
        // Trakt is the watch-sync authority and is NOT one of the merge identity's
        // external namespaces, so it stays the highest-priority canonical key.
        for (key, value) in providerIDs where key.lowercased() == "trakt" {
            let v = value.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return "trakt:\(v.lowercased())" }
        }
        // Then mirror the merge identity's strong external namespaces via the same
        // alias-insensitive resolution (`providerID(_:)`), so `TheTvdb`, `TMDb ID`,
        // `myanimelist`, an AniList/MAL/AniDB/TVmaze-only anime series, etc. all
        // produce the same canonical id the merger keys on.
        for entry in MediaItemIdentity.strongExternalNamespaces {
            if let value = providerIDs.providerID(entry.namespace)?.trimmingCharacters(in: .whitespaces),
               !value.isEmpty {
                return "\(entry.canonical):\(value.lowercased())"
            }
        }
        // Kind-scoped title fallback (see doc above). Uses the SAME normalization as
        // the merge identity (accent-fold + punctuation-strip + whitespace-collapse)
        // so "Spider-Man" and "spider man" canonicalise identically.
        if let title {
            let slug = MediaItemIdentity.normalizedTitle(title)
            if !slug.isEmpty {
                switch kind {
                case .movie:
                    if let year { return "title:\(slug):\(year)" }
                case .episode:
                    return year.map { "title:\(slug):\($0)" } ?? "title:\(slug)"
                default:
                    break
                }
            }
        }
        return "local:\(fallback)"
    }

    /// Day bucket (UTC `yyyy-MM-dd`) for the Trakt idempotency key / TTL pruning.
    public static func dayBucket(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

public extension Calendar {
    /// ISO-8601 calendar pinned to UTC — deterministic day bucketing regardless of
    /// device timezone, so a watch near midnight buckets consistently.
    static var iso8601UTC: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
}
