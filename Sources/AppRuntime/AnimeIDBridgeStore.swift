import CoreModels
import Foundation

/// Loads and caches the anime id mappings that let a tracker's show and a
/// server's show be recognised as one title.
///
/// The dataset is the community `anime-lists` mapping — the same source
/// Sonarr's and Jellyfin's anime handling use — because this problem has one
/// correct answer and it is not one an app can derive for itself. AniList and
/// MyAnimeList ids simply do not appear anywhere in a Plex or Jellyfin library,
/// so the equivalence has to be looked up somewhere that maintains it.
///
/// Cached durably and refreshed rarely: mappings change when new anime is
/// catalogued, not by the hour, and the watchlist must not depend on a network
/// fetch to know what the viewer owns. A stale mapping is strictly better than
/// none — it is what the app had yesterday, and it merges everything it knew
/// about then.
public actor AnimeIDBridgeStore {
    /// Where the mappings come from. A single flat JSON array of rows, each
    /// naming a show in whichever id spaces it has.
    ///
    /// `Fribb/anime-lists` is the maintained aggregate of the older
    /// `anime-offline-database` + `anime-lists` sources, published as one file
    /// that already contains every namespace this needs.
    public static let defaultSourceURL = URL(
        string: "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-mini.json"
    )!

    /// How long a cached copy is used before a refresh is attempted. The
    /// refresh is opportunistic — a failure keeps serving what we have.
    private static let refreshInterval: TimeInterval = 60 * 60 * 24 * 7

    private struct Cache: Codable {
        static let currentVersion = 1
        var version: Int
        var fetchedAt: Date
        var mappings: [AnimeIDMapping]
    }

    /// One row of the source dataset. Ids arrive as numbers or strings
    /// depending on the namespace, so each is decoded leniently and normalised
    /// to a string — the ledger keys on strings, and `12345` and `"12345"` must
    /// not become two different shows.
    private struct SourceRow: Decodable {
        let aniDB: String?
        let aniList: String?
        let mal: String?
        let tmdb: String?
        let tvdb: String?
        let imdb: String?

        private enum CodingKeys: String, CodingKey {
            // Spelled exactly as the published file does. `tvdb_id`, not
            // `thetvdb_id` — an older sibling dataset uses the longer name, and
            // guessing it cost a silently absent id that a test caught.
            case anidb_id, anilist_id, mal_id, themoviedb_id, tvdb_id, imdb_id
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            aniDB = Self.string(container, .anidb_id)
            aniList = Self.string(container, .anilist_id)
            mal = Self.string(container, .mal_id)
            tmdb = Self.string(container, .themoviedb_id)
            tvdb = Self.string(container, .tvdb_id)
            imdb = Self.string(container, .imdb_id)
        }

        /// The dataset is not uniformly typed, and assuming it was is how a
        /// mapping file silently parses to nothing: `anidb_id` is a number,
        /// `imdb_id` is an ARRAY of strings, and `themoviedb_id` is an OBJECT
        /// keyed by `movie` or `tv`. Each shape is accepted explicitly.
        private static func string(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> String? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return normalized(value)
            }
            // `imdb_id: ["tt0286390"]`. A row naming several is ambiguous about
            // which title it means, so only a single-element list is used.
            if let values = try? container.decodeIfPresent([String].self, forKey: key) {
                guard values.count == 1 else { return nil }
                return normalized(values[0])
            }
            // `themoviedb_id: {"tv": 26209}` / `{"movie": 12345}`.
            if let value = try? container.decodeIfPresent(
                [String: Int].self,
                forKey: key
            ) {
                guard value.count == 1, let first = value.values.first else {
                    return nil
                }
                return String(first)
            }
            return nil
        }

        private static func normalized(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Some columns spell an absent id as "unknown" rather than omitting it.
            guard !trimmed.isEmpty, trimmed.lowercased() != "unknown" else {
                return nil
            }
            return trimmed
        }

        var mapping: AnimeIDMapping? {
            let value = AnimeIDMapping(
                aniDB: aniDB,
                aniList: aniList,
                myAnimeList: mal,
                tmdb: tmdb,
                tvdb: tvdb,
                imdb: imdb
            )
            // A row naming fewer than two id spaces bridges nothing.
            return value.identities.count > 1 ? value : nil
        }
    }

    private let fileURL: URL?
    private let fetch: @Sendable (URL) async throws -> Data
    private let sourceURL: URL
    private var loaded: AnimeIDBridge?

    public init(
        directoryURL: URL?,
        sourceURL: URL = AnimeIDBridgeStore.defaultSourceURL,
        fetch: @escaping @Sendable (URL) async throws -> Data = { url in
            try await URLSession.shared.data(from: url).0
        }
    ) {
        fileURL = directoryURL?
            .appendingPathComponent("anime-id-bridge-v1.json")
        self.sourceURL = sourceURL
        self.fetch = fetch
    }

    /// The bridge, from memory or disk. Never performs a network fetch, so a
    /// caller on a hot path can ask freely.
    public func bridge() -> AnimeIDBridge {
        if let loaded { return loaded }
        let value = loadFromDisk().map { AnimeIDBridge(mappings: $0.mappings) }
            ?? .empty
        loaded = value
        return value
    }

    /// Refreshes the cached mappings when they are missing or stale.
    ///
    /// Best-effort by design: a failure leaves whatever is cached in place and
    /// returns it. The watchlist has to work on a plane.
    @discardableResult
    public func refreshIfNeeded(now: Date = Date()) async -> AnimeIDBridge {
        let cached = loadFromDisk()
        if let cached,
           now.timeIntervalSince(cached.fetchedAt) < Self.refreshInterval {
            let value = AnimeIDBridge(mappings: cached.mappings)
            loaded = value
            return value
        }
        guard let data = try? await fetch(sourceURL),
              let rows = try? JSONDecoder().decode([SourceRow].self, from: data)
        else {
            let value = cached.map { AnimeIDBridge(mappings: $0.mappings) } ?? .empty
            loaded = value
            return value
        }
        let mappings = rows.compactMap(\.mapping)
        guard !mappings.isEmpty else {
            let value = cached.map { AnimeIDBridge(mappings: $0.mappings) } ?? .empty
            loaded = value
            return value
        }
        save(Cache(
            version: Cache.currentVersion,
            fetchedAt: now,
            mappings: mappings
        ))
        let value = AnimeIDBridge(mappings: mappings)
        loaded = value
        return value
    }

    private func loadFromDisk() -> Cache? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Cache.currentVersion else { return nil }
        return cache
    }

    private func save(_ cache: Cache) {
        guard let fileURL, let data = try? JSONEncoder().encode(cache) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic])
    }
}
