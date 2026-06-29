import Foundation
import CoreModels

/// In-memory per-session memo of resolved lyrics, keyed by `MusicTrack.id`.
/// Bounded so a long listening session can't grow it without limit. Evicting
/// the oldest entry when full is fine — lyrics rarely change for the same
/// track, and a miss just falls through to the disk cache or the network
/// (both also fast).
actor LyricsMemoCache {
    static let shared = LyricsMemoCache()

    private var entries: [String: Lyrics?] = [:]
    private var order: [String] = []
    private let limit = 64

    func value(for key: String) -> Lyrics?? {
        guard let entry = entries[key] else { return nil }
        return .some(entry)
    }

    func set(_ value: Lyrics?, for key: String) {
        if entries[key] == nil {
            order.append(key)
            if order.count > limit, let evicted = order.first {
                order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
        entries[key] = value
    }
}

/// Persistent, on-disk cache of resolved lyrics keyed by `MusicTrack.id`. Lives
/// alongside `MetadataDiskCache` in the user's Caches directory so the OS can
/// reclaim it under pressure without losing user data.
///
/// Caches **both** positives and negatives:
///
///  * A positive entry (`lyrics != nil`) means "we already fetched and parsed
///    synced lyrics for this track" — re-opening it is instant on the next
///    launch, not just in the same session.
///  * A negative entry (`lyrics == nil`) means "this track resolved to no
///    synced lyrics anywhere". This is the big win for purely instrumental
///    pieces (classical, score) like *Palladio* by Escala — once we've asked
///    once, we never ask again until the entry expires, and the panel goes
///    straight to its "No lyrics found" state.
///
/// Per-song JSON encodes to roughly 3 KB, so a heavy listening history of a
/// few thousand tracks costs only a handful of MB on disk — gzip would halve
/// that but isn't needed at this scale. Entries are dropped from memory on
/// load when expired so the file self-prunes over time.
public actor LyricsDiskCache {
    public static let shared = LyricsDiskCache()

    private struct Entry: Codable {
        let lyrics: Lyrics?
        let expires: Date
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL?
    private let positiveTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private var loaded = false
    private var dirty = false
    private var persistTask: Task<Void, Never>?

    /// The on-disk cache filename carries a schema version, mirroring the
    /// metadata cache, so bumping the version cleanly starts fresh if the
    /// `Lyrics` shape ever evolves.
    private static let cacheFileName = "plozz-lyrics-cache-v1.json"
    private static let cacheFilePrefix = "plozz-lyrics-cache"

    public init(
        directory: URL? = LyricsDiskCache.defaultDirectory(),
        positiveTTL: TimeInterval = 60 * 60 * 24 * 30,
        negativeTTL: TimeInterval = 60 * 60 * 24 * 14
    ) {
        self.fileURL = directory?.appendingPathComponent(Self.cacheFileName)
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
        if let directory { Self.removeSupersededCaches(in: directory) }
    }

    /// Returns the cached entry for `key`:
    /// - `.some(.some(lyrics))` for a fresh positive hit (use these lyrics);
    /// - `.some(.none)` for a fresh remembered "no lyrics" answer (skip the
    ///   network and show the empty state);
    /// - `nil` when there's no fresh entry and the caller should resolve.
    public func cached(_ key: String) -> Lyrics?? {
        loadIfNeeded()
        guard let entry = entries[key], entry.expires > Date() else { return nil }
        return .some(entry.lyrics)
    }

    /// Stores a resolved result for `key`, using a shorter TTL for negatives
    /// so the rare case of LRCLIB picking up new lyrics for a track doesn't
    /// stay invisible to the user for a month.
    public func store(_ lyrics: Lyrics?, for key: String) {
        loadIfNeeded()
        let ttl = lyrics == nil ? negativeTTL : positiveTTL
        entries[key] = Entry(lyrics: lyrics, expires: Date().addingTimeInterval(ttl))
        dirty = true
        schedulePersist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        // Drop already-expired entries on load so the file self-prunes.
        let now = Date()
        entries = decoded.filter { $0.value.expires > now }
        // If pruning actually removed anything, mark dirty so the trimmed set
        // gets written back on the next change without forcing an immediate IO.
        if entries.count != decoded.count { dirty = true }
    }

    /// Debounces writes so a burst of `store` calls (e.g. an album prefetch)
    /// produces one disk write rather than one per track.
    private func schedulePersist() {
        guard dirty else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    private func persist() {
        guard dirty, let fileURL else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Deletes older-versioned cache files so each schema bump self-cleans
    /// its predecessor rather than leaving orphans on disk.
    private static func removeSupersededCaches(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent != cacheFileName
            && file.lastPathComponent.hasPrefix(cacheFilePrefix)
            && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}

/// Whether a track title carries an explicit marker that it has no sung
/// lyrics — `(Instrumental)`, `[Karaoke]`, `Backing Track`, etc. These rarely
/// have synced lyrics on LRCLIB or anywhere else, so we can skip the lookup
/// entirely and resolve to "no lyrics" immediately, saving the round-trip.
///
/// Intentionally narrow so we don't false-positive on songs that just *mention*
/// these words (e.g. "Karaoke" by Drake actually has lyrics). Untitled
/// instrumentals like a classical piece named "Palladio" aren't caught here
/// — those rely on `LyricsDiskCache` remembering the negative result instead.
func isExplicitlyInstrumental(title: String) -> Bool {
    let pattern = "(?i)[\\(\\[\\-–—]\\s*(instrumental|karaoke|backing\\s+track|score\\s+version|instrumental\\s+version|karaoke\\s+version)\\s*[\\)\\]]?\\s*$"
    return title.range(of: pattern, options: .regularExpression) != nil
}
