import Foundation

/// Keyless music artwork from the **Deezer** public API (`api.deezer.com`).
///
/// Deezer's read endpoints need no key, no OAuth, and no account — just HTTP GET —
/// and return direct CDN image URLs in several sizes. Per-IP throttled, so it
/// scales with the user base. This is Plozz's primary source of *artist* hero
/// imagery (`picture_xl`, ~1000px) and a strong album-cover fallback (`cover_xl`)
/// for libraries whose own server ships no music art.
public struct DeezerMusicProvider: Sendable {
    public init() {}

    /// A large artist image suitable for a music hero/background, by artist name.
    public func artistImageURL(artist: String) async -> URL? {
        guard let escaped = metadataEscaped(artist),
              let url = URL(string: "https://api.deezer.com/search/artist?q=\(escaped)&limit=1")
        else { return nil }
        let response = await MetadataHTTP.get(ArtistSearch.self, url: url)
        let raw = response?.data.first?.picture_xl ?? response?.data.first?.picture_big
        return raw.flatMap { URL(string: $0) }
    }

    /// A large album cover, by `artist` + `album` (artist disambiguates the title).
    public func albumCoverURL(artist: String?, album: String) async -> URL? {
        let queryText = [artist, album].compactMap { $0 }.joined(separator: " ")
        guard let escaped = metadataEscaped(queryText),
              let url = URL(string: "https://api.deezer.com/search/album?q=\(escaped)&limit=1")
        else { return nil }
        let response = await MetadataHTTP.get(AlbumSearch.self, url: url)
        let raw = response?.data.first?.cover_xl ?? response?.data.first?.cover_big
        return raw.flatMap { URL(string: $0) }
    }

    private struct ArtistSearch: Decodable {
        let data: [Artist]
        struct Artist: Decodable {
            let picture_big: String?
            let picture_xl: String?
        }
    }

    private struct AlbumSearch: Decodable {
        let data: [Album]
        struct Album: Decodable {
            let cover_big: String?
            let cover_xl: String?
        }
    }
}

/// Keyless album cover art from **MusicBrainz** + the **Cover Art Archive**.
///
/// MusicBrainz needs no key (only a descriptive User-Agent, which `MetadataHTTP`
/// sends) and is polite at ~1 req/s per IP; the Cover Art Archive serves the
/// images keylessly from its CDN. Used as the album-cover fallback after Deezer.
public struct MusicBrainzArtworkProvider: Sendable {
    public init() {}

    /// A front cover for `album` by `artist`, via MBID → Cover Art Archive.
    public func albumCoverURL(artist: String?, album: String) async -> URL? {
        var queryParts = ["release:\"\(album)\""]
        if let artist, !artist.isEmpty { queryParts.append("artist:\"\(artist)\"") }
        let lucene = queryParts.joined(separator: " AND ")
        guard let escaped = metadataEscaped(lucene),
              let url = URL(string: "https://musicbrainz.org/ws/2/release/?query=\(escaped)&fmt=json&limit=1")
        else { return nil }
        guard let response = await MetadataHTTP.get(ReleaseSearch.self, url: url),
              let mbid = response.releases.first?.id
        else { return nil }
        // Cover Art Archive serves a sized front image directly; 500px is crisp on
        // a card without pulling a multi-megabyte original.
        return URL(string: "https://coverartarchive.org/release/\(mbid)/front-500")
    }

    private struct ReleaseSearch: Decodable {
        let releases: [Release]
        struct Release: Decodable { let id: String }
    }
}
