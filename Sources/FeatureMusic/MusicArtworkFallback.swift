import Foundation
import MetadataKit

/// Bridges the music UI to MetadataKit's keyless artwork providers via
/// ``ArtworkRouter``. Each factory returns a best-effort `@Sendable` closure that
/// `FallbackAsyncImage` invokes **only when the server supplies no art**, so the
/// user's own Jellyfin/Plex library art always wins and MetadataKit (Deezer
/// artist hero + Cover Art Archive / Deezer album cover) merely fills gaps.
///
/// Resolved URLs are memoized in the router's persistent ``MetadataDiskCache``
/// and the decoded bytes in CoreUI's `ArtworkImageCache`, so there is a single
/// caching path shared with the rest of the app. Returns `nil` (meaning "no
/// fallback to attempt") when there is nothing meaningful to search by.
enum MusicArtworkFallback {
    /// Album cover (Deezer → Cover Art Archive), by album title disambiguated by
    /// artist. `nil` when the title is blank.
    static func albumCover(title: String, artist: String?) -> (@Sendable () async -> URL?)? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artistQuery = (cleanArtist?.isEmpty == false) ? cleanArtist : nil
        return {
            await ArtworkRouter.shared.albumCoverURL(artist: artistQuery, album: cleanTitle)
        }
    }

    /// Artist hero image (Deezer `picture_xl`), by artist name. `nil` when blank.
    static func artistImage(name: String) -> (@Sendable () async -> URL?)? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }
        return {
            await ArtworkRouter.shared.artistImageURL(artist: cleanName)
        }
    }

    /// Album-cover fallback for a single track: prefers the track's album title,
    /// falling back to the track title, disambiguated by artist.
    static func trackCover(title: String, album: String?, artist: String?) -> (@Sendable () async -> URL?)? {
        let cleanAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanAlbum, !cleanAlbum.isEmpty {
            return albumCover(title: cleanAlbum, artist: artist)
        }
        return albumCover(title: title, artist: artist)
    }
}
