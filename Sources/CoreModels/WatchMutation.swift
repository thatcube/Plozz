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
        attempts: Int = 0
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

    /// Whether every server target AND the Trakt mirror are done — safe to prune.
    public var isFullyApplied: Bool {
        targets.isEmpty && !traktPending
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
