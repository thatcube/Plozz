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
        duration: TimeInterval?
    ) async -> Lyrics? {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty else { return nil }
        let candidates = titleCandidates(from: title)
        guard !candidates.isEmpty else { return nil }

        // Fan out every candidate × {/get, /search} concurrently and take the
        // first synced result, cancelling the rest. Previously these ran
        // sequentially (up to 4 round-trips waited on serially), which is the
        // main reason lyrics sometimes took several seconds to appear.
        return await withTaskGroup(of: Lyrics?.self) { group in
            for candidate in candidates {
                group.addTask {
                    await self.exactMatch(
                        title: candidate, artist: trimmedArtist, album: album, duration: duration
                    )?.lyrics()
                }
                group.addTask {
                    await self.search(
                        title: candidate, artist: trimmedArtist, duration: duration
                    )?.lyrics()
                }
            }
            var plainFallback: Lyrics?
            for await result in group {
                guard let lyrics = result else { continue }
                if lyrics.isSynced {
                    group.cancelAll()
                    return lyrics
                }
                if plainFallback == nil { plainFallback = lyrics }
            }
            return plainFallback
        }
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
    ) async -> LRCLIBRecord? {
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
        guard let url = makeURL(path: "/get", queryItems: items) else { return nil }
        return await MetadataHTTP.get(LRCLIBRecord.self, url: url)
    }

    private func search(title: String, artist: String, duration: TimeInterval?) async -> LRCLIBRecord? {
        let items = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = makeURL(path: "/search", queryItems: items),
              let results = await MetadataHTTP.get([LRCLIBRecord].self, url: url),
              !results.isEmpty else {
            return nil
        }
        return bestMatch(in: results, duration: duration)
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
