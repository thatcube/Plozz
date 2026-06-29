import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keyless public fallback for song lyrics, backed by lrclib.net.
///
/// Used only when the user's own server (Jellyfin/Plex) has no lyrics for the
/// track. Like the artwork providers it is best-effort: every failure (network,
/// 404, decode, instrumental) collapses to `nil` so the UI simply shows its
/// empty state. No API key is required, satisfying the app's keyless mandate.
public struct LRCLIBLyricsProvider: Sendable {
    private static let base = "https://lrclib.net/api"

    /// Shared app-wide rate limiter so *every* LRCLIB request — current-track
    /// lookups, next-track prefetch, and the bulk queue sweep combined — stays
    /// within polite limits for the keyless public endpoint. A single visible
    /// lookup fans out a few requests; `burst` lets those go out immediately
    /// while sustained background traffic is throttled toward ~`requestsPerSecond`.
    static let rateLimiter = RateLimiter(requestsPerSecond: 2.0, burst: 8)

    public init() {}

    /// Looks up lyrics for a track, **preferring a synced version**. Tries the
    /// track's title as-is and a cleaned variant (parentheticals like
    /// `(from the Short Film …)` / `(feat. …)` stripped), since LRCLIB uploads
    /// are usually filed under the plain song title. For each candidate it tries
    /// the exact `/get` endpoint then `/search`, returning the first synced hit
    /// and falling back to plain text only if nothing synced is found anywhere.
    public func lyrics(
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?,
        allowTitleOnlyFallback: Bool = true
    ) async -> Lyrics? {
        await lyricsWithStatus(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            allowTitleOnlyFallback: allowTitleOnlyFallback
        ).lyrics
    }

    /// Same fan-out lookup as `lyrics(...)`, but also reports whether *any*
    /// sub-request actually reached lrclib.net. Callers (the lyrics resolver)
    /// use this `reachable` flag to avoid caching a "no lyrics" answer when
    /// the device is simply offline — a missing answer in that case is
    /// transport noise, not a real verdict.
    public func lyricsWithStatus(
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?,
        allowTitleOnlyFallback: Bool = true
    ) async -> (lyrics: Lyrics?, reachable: Bool) {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty else { return (nil, false) }
        let candidates = titleCandidates(from: title)
        guard !candidates.isEmpty else { return (nil, false) }

        struct Probe { let lyrics: Lyrics?; let reachable: Bool }

        // Fan out every candidate × {/get, /search} concurrently and take the
        // first synced result, cancelling the rest. Previously these ran
        // sequentially (up to 4 round-trips waited on serially), which is the
        // main reason lyrics sometimes took several seconds to appear.
        let artistQualified: (lyrics: Lyrics?, reachable: Bool) = await withTaskGroup(of: Probe.self) { group in
            for candidate in candidates {
                group.addTask {
                    let result = await self.exactMatch(
                        title: candidate, artist: trimmedArtist, album: album, duration: duration
                    )
                    return Probe(lyrics: result.record?.lyrics(), reachable: result.reachable)
                }
                group.addTask {
                    let result = await self.search(
                        title: candidate, artist: trimmedArtist, duration: duration
                    )
                    return Probe(lyrics: result.record?.lyrics(), reachable: result.reachable)
                }
            }
            var plainFallback: Lyrics?
            var anyReachable = false
            for await probe in group {
                if probe.reachable { anyReachable = true }
                guard let lyrics = probe.lyrics else { continue }
                if lyrics.isSynced {
                    group.cancelAll()
                    return (lyrics, true)
                }
                if plainFallback == nil { plainFallback = lyrics }
            }
            return (plainFallback, anyReachable)
        }

        // A synced hit from the artist-qualified pass wins outright.
        if let lyrics = artistQualified.lyrics, lyrics.isSynced {
            return (lyrics, true)
        }

        // Fallback: some catalogues file a track under a *different* artist name
        // than the player shows — a collaboration credited to the duo's name
        // (e.g. "Bad Meets Evil" for an "Eminem, Royce da 5'9\"" track), a
        // soundtrack under "Various Artists", or classical filed by composer
        // rather than performer. When the artist-qualified search finds nothing,
        // retry by **title only** and accept a record solely on a tight duration
        // match: without an artist to match on, duration is the guard that keeps
        // same-title / different-song results out. Gated on a known duration and
        // run only on the miss path, so it never overrides an artist match.
        // `allowTitleOnlyFallback` is false for background prefetch: the extra
        // per-track title-only round-trips aren't worth the shared rate-limiter
        // contention when warming the queue, and the track still gets the full
        // fallback on-demand the moment it becomes the visible Now Playing item.
        var bestPlain = artistQualified.lyrics
        var reachable = artistQualified.reachable
        if allowTitleOnlyFallback, artistQualified.lyrics == nil, let duration, duration > 0 {
            for candidate in candidates {
                let result = await searchByTitleOnly(title: candidate, duration: duration)
                if result.reachable { reachable = true }
                guard let lyrics = result.record?.lyrics() else { continue }
                if lyrics.isSynced {
                    return (lyrics, true)
                }
                if bestPlain == nil { bestPlain = lyrics }
            }
        }
        return (bestPlain, reachable)
    }

    /// The ordered, de-duplicated title queries to try: the original first, then
    /// a cleaned variant with parentheticals / `feat.` segments removed.
    private func titleCandidates(from rawTitle: String) -> [String] {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var candidates = [trimmed]
        let cleaned = Self.cleanedTitle(trimmed)
        if !cleaned.isEmpty, cleaned.caseInsensitiveCompare(trimmed) != .orderedSame {
            candidates.append(cleaned)
        }
        return candidates
    }

    /// Strips trailing/embedded `(...)` and `[...]` groups and `feat.`/`ft.`
    /// segments so a verbose store title collapses to the core song name.
    static func cleanedTitle(_ title: String) -> String {
        var result = title
        result = result.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)\\s*[-–—]?\\s*feat\\.?\\s.*$", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)\\s*[-–—]?\\s*ft\\.?\\s.*$", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func exactMatch(
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?
    ) async -> (record: LRCLIBRecord?, reachable: Bool) {
        var items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if let album, !album.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration, duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        guard let url = makeURL(path: "/get", queryItems: items) else { return (nil, false) }
        await Self.rateLimiter.acquire()
        let result = await MetadataHTTP.getWithStatus(LRCLIBRecord.self, url: url)
        return (result.value, result.reachable)
    }

    private func search(title: String, artist: String, duration: TimeInterval?) async -> (record: LRCLIBRecord?, reachable: Bool) {
        let items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = makeURL(path: "/search", queryItems: items) else { return (nil, false) }
        await Self.rateLimiter.acquire()
        let result = await MetadataHTTP.getWithStatus([LRCLIBRecord].self, url: url)
        guard let results = result.value, !results.isEmpty else {
            return (nil, result.reachable)
        }
        return (bestMatch(in: results, duration: duration), result.reachable)
    }

    /// Last-resort lookup used only when artist-qualified search finds nothing:
    /// query by **title alone** and accept a record solely when its duration is
    /// within a tight window of the playing track. Without an artist match,
    /// duration is the only safeguard against unrelated songs that merely share
    /// a title, so the tolerance is deliberately small.
    private func searchByTitleOnly(title: String, duration: TimeInterval) async -> (record: LRCLIBRecord?, reachable: Bool) {
        let items = [URLQueryItem(name: "track_name", value: title)]
        guard let url = makeURL(path: "/search", queryItems: items) else { return (nil, false) }
        await Self.rateLimiter.acquire()
        let result = await MetadataHTTP.getWithStatus([LRCLIBRecord].self, url: url)
        guard let records = result.value, !records.isEmpty else { return (nil, result.reachable) }
        let tolerance: TimeInterval = 3
        let inWindow = records.filter { record in
            guard let recordDuration = record.duration else { return false }
            return abs(recordDuration - duration) <= tolerance
        }
        return (bestMatch(in: inWindow, duration: duration), result.reachable)
    }

    /// Picks the best record: first prefer ones with **synced** lyrics, then —
    /// when a duration is known — the one whose duration is closest.
    private func bestMatch(in records: [LRCLIBRecord], duration: TimeInterval?) -> LRCLIBRecord? {
        let usable = records.filter { $0.lyrics() != nil }
        guard !usable.isEmpty else { return nil }
        // Prefer synced records when any exist, so the panel can scroll/highlight.
        let synced = usable.filter { $0.hasSyncedLyrics }
        let pool = synced.isEmpty ? usable : synced
        guard let duration, duration > 0 else { return pool.first }
        return pool.min { lhs, rhs in
            abs((lhs.duration ?? .greatestFiniteMagnitude) - duration)
                < abs((rhs.duration ?? .greatestFiniteMagnitude) - duration)
        }
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: Self.base + path)
        components?.queryItems = queryItems
        return components?.url
    }
}

/// A lrclib.net record. The `/get` endpoint returns one; `/search` an array.
private struct LRCLIBRecord: Decodable {
    let duration: TimeInterval?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    /// Whether this record carries usable synced (timestamped) lyrics.
    var hasSyncedLyrics: Bool {
        guard let synced = syncedLyrics, let parsed = Lyrics(lrc: synced) else { return false }
        return parsed.isSynced && !parsed.isEmpty
    }

    /// Converts the record into a tagged `Lyrics`, preferring synced over plain,
    /// returning `nil` for instrumentals or empty payloads.
    func lyrics() -> Lyrics? {
        if instrumental == true { return nil }
        if let synced = syncedLyrics, let parsed = Lyrics(lrc: synced), !parsed.isEmpty {
            return parsed.taggingSource(.lrclib)
        }
        if let plain = plainLyrics {
            let parsed = Lyrics(plainText: plain)
            if !parsed.isEmpty { return parsed.taggingSource(.lrclib) }
        }
        return nil
    }
}
