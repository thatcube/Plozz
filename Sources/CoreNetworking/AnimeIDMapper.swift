import Foundation
import CoreModels
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The cross-database anime ids the trackers care about. Plex/Jellyfin (and
/// Shoko-backed Jellyfin libraries) usually expose only one of these — most
/// often AniDB — so a MAL-only or AniList-only user can't be scrobbled without
/// translating between them. This holds whatever is known and what we resolved.
public struct AnimeMappedIDs: Sendable, Equatable, Hashable, Codable {
    public var anidb: Int?
    public var mal: Int?
    public var anilist: Int?
    public var kitsu: Int?

    public init(anidb: Int? = nil, mal: Int? = nil, anilist: Int? = nil, kitsu: Int? = nil) {
        self.anidb = anidb
        self.mal = mal
        self.anilist = anilist
        self.kitsu = kitsu
    }

    public var isEmpty: Bool { anidb == nil && mal == nil && anilist == nil && kitsu == nil }
    /// Both list trackers can act once we have either of their native ids.
    public var hasMALAndAniList: Bool { mal != nil && anilist != nil }
}

/// Resolves anime ids across AniDB ↔ MyAnimeList ↔ AniList ↔ Kitsu on demand and
/// caches the (tiny) result, so a MAL/AniList-only user can still be scrobbled
/// when their server only tags AniDB. Lean by design: no 58 MB offline database
/// to download or keep fresh — a few-byte lookup per anime title, queried once
/// and cached forever, against the public ARM (Anime Relations Map) service.
///
/// Shared so the cache is one source of truth across both anime scrobblers and
/// every server, and so a title resolves at most once per device.
public actor AnimeIDMapper {
    public static let shared = AnimeIDMapper()

    private let http: HTTPClient
    private let baseURL: URL
    /// In-memory cache keyed by `"source:id"`; mirrors the disk store.
    private var cache: [String: AnimeMappedIDs]
    private let cacheURL: URL?

    public init(
        http: HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = URL(string: "https://arm.haglund.dev")!
    ) {
        self.http = http
        self.baseURL = baseURL
        self.cacheURL = Self.makeCacheURL()
        self.cache = Self.loadCache(from: cacheURL)
    }

    /// Returns the input ids enriched with any MAL/AniList ids we can translate
    /// to. A best-effort, non-throwing call: on any failure it returns what it
    /// was given so the caller degrades gracefully. Resolves at most one network
    /// query and caches the result (positive *and* negative) keyed by source id.
    public func enrich(_ ids: AnimeMappedIDs) async -> AnimeMappedIDs {
        // Nothing to do — already actionable for both trackers, or no anchor id.
        if ids.hasMALAndAniList { return ids }
        guard let (source, id) = preferredSource(ids) else { return ids }

        let key = "\(source):\(id)"
        if let cached = cache[key] { return merge(ids, cached) }

        let resolved = await fetch(source: source, id: id)
        cache[key] = resolved ?? ids   // negative cache: don't re-query a miss
        persist()
        return merge(ids, resolved ?? AnimeMappedIDs())
    }

    // MARK: - Source selection

    /// Picks the most reliable known id to translate from. AniDB is the common
    /// Shoko/Jellyfin case; the native list ids are exact when present.
    private func preferredSource(_ ids: AnimeMappedIDs) -> (String, Int)? {
        if let v = ids.anilist { return ("anilist", v) }
        if let v = ids.mal { return ("myanimelist", v) }
        if let v = ids.anidb { return ("anidb", v) }
        if let v = ids.kitsu { return ("kitsu", v) }
        return nil
    }

    private func merge(_ base: AnimeMappedIDs, _ extra: AnimeMappedIDs) -> AnimeMappedIDs {
        AnimeMappedIDs(
            anidb: base.anidb ?? extra.anidb,
            mal: base.mal ?? extra.mal,
            anilist: base.anilist ?? extra.anilist,
            kitsu: base.kitsu ?? extra.kitsu
        )
    }

    // MARK: - Network

    private struct ARMRecord: Decodable {
        let anidb: Int?
        let anilist: Int?
        let myanimelist: Int?
        let kitsu: Int?
    }

    private func fetch(source: String, id: Int) async -> AnimeMappedIDs? {
        let endpoint = Endpoint(
            method: .get,
            path: "/api/v2/ids",
            queryItems: [
                URLQueryItem(name: "source", value: source),
                URLQueryItem(name: "id", value: String(id))
            ]
        )
        do {
            let rec = try await http.decode(ARMRecord.self, from: endpoint, baseURL: baseURL, decoder: JSONDecoder())
            return AnimeMappedIDs(anidb: rec.anidb, mal: rec.myanimelist, anilist: rec.anilist, kitsu: rec.kitsu)
        } catch {
            PlozzLog.networking.debug("AnimeIDMapper lookup failed (non-fatal) for \(source):\(id)")
            return nil
        }
    }

    // MARK: - Persistence (tiny: a few ints per anime ever played)

    private func persist() {
        guard let cacheURL else { return }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func makeCacheURL() -> URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return dir.appendingPathComponent("plozz-anime-id-map.json")
    }

    private static func loadCache(from url: URL?) -> [String: AnimeMappedIDs] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: AnimeMappedIDs].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
