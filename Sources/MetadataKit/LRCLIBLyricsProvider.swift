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

    /// Looks up lyrics for a track. Tries the exact signature endpoint first
    /// (artist + title + album + duration), then a fuzzy search, preferring
    /// synced lyrics and — when a duration is known — the closest match.
    public func lyrics(
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?
    ) async -> Lyrics? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedArtist.isEmpty else { return nil }

        // Prefer a synced result. The exact `/get` match is best when it's
        // synced; otherwise keep it as a plain fallback and try `/search`, which
        // can surface a synced copy from another upload.
        let exact = await exactMatch(title: trimmedTitle, artist: trimmedArtist, album: album, duration: duration)
        if let exactLyrics = exact?.lyrics(), exactLyrics.isSynced {
            return exactLyrics
        }
        if let searched = await search(title: trimmedTitle, artist: trimmedArtist, duration: duration),
           let searchedLyrics = searched.lyrics() {
            if searchedLyrics.isSynced { return searchedLyrics }
            // Neither is synced: keep the exact match if it had anything.
            return exact?.lyrics() ?? searchedLyrics
        }
        return exact?.lyrics()
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
