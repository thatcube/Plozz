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
        year: Int?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        providerIDs: [String: String],
        progress: Double
    ) {
        self.kind = kind
        self.title = title
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
        identities: [MediaIdentity] = []
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
        self.attempts = attempts
        self.episodeOrigin = episodeOrigin
        self.expansionPending = expansionPending
        self.identities = identities
    }

    // MARK: - Codable (back-compatible)

    private enum CodingKeys: String, CodingKey {
        case id, capturedAt, canonicalMediaID, seasonNumber, episodeNumber
        case resumePosition, played, clearResume, targets, trakt, traktPending
        case attempts, episodeOrigin, expansionPending, identities
    }

    /// Decodes tolerating outbox files written before `episodeOrigin` /
    /// `expansionPending` / `identities` existed (they decode to `nil` / `false` /
    /// `[]`), so an in-app upgrade never drops a queued watch. `encode(to:)` is
    /// synthesized.
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
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        episodeOrigin = try container.decodeIfPresent(EpisodeOrigin.self, forKey: .episodeOrigin)
        expansionPending = try container.decodeIfPresent(Bool.self, forKey: .expansionPending) ?? false
        identities = try container.decodeIfPresent([MediaIdentity].self, forKey: .identities) ?? []
    }

    /// Title-level key used to COALESCE queued mutations (latest wins, targets
    /// unioned) and to key the stale-write clock. Excludes the account/day so any
    /// server's write for the same title/episode collapses to one queue entry.
    public var coalesceKey: String {
        "\(canonicalMediaID)|s\(seasonNumber.map(String.init) ?? "-")|e\(episodeNumber.map(String.init) ?? "-")"
    }

    /// Durable Trakt idempotency key (`profile | canonicalMediaId | episode |
    /// day_bucket`) so our own replays across relaunch don't double-write history.
    /// `profile` is folded in by the reconciler (its store is profile-scoped) so it
    /// is omitted here.
    public func traktIdempotencyKey(dayBucket: String) -> String {
        "\(coalesceKey)|\(dayBucket)"
    }

    /// Whether every server target AND the Trakt mirror are done **and** no
    /// cross-server twin expansion is still owed — safe to prune. Keeping a
    /// mutation alive while `expansionPending` ensures an episode whose twin server
    /// was asleep at the first drain still fans out on a later one.
    public var isFullyApplied: Bool {
        targets.isEmpty && !traktPending && !expansionPending
    }

    // MARK: - Canonical id

    /// Derives a stable cross-server canonical id from a provider id map, preferring
    /// the most authoritative namespace. Falls back to a normalized title (+year)
    /// and finally to a supplied per-item id so a title with no external ids still
    /// enqueues safely (it just won't coalesce across servers — which it couldn't
    /// have merged across anyway).
    public static func canonicalMediaID(
        providerIDs: [String: String],
        title: String? = nil,
        year: Int? = nil,
        fallback: String
    ) -> String {
        let normalized: [String: String] = Dictionary(
            providerIDs.compactMap { key, value in
                let v = value.trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : (key.lowercased(), v)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for namespace in ["trakt", "imdb", "tmdb", "tvdb"] {
            if let value = normalized[namespace] {
                return "\(namespace):\(value)"
            }
        }
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            let slug = title.lowercased().trimmingCharacters(in: .whitespaces)
            return year.map { "title:\(slug):\($0)" } ?? "title:\(slug)"
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
