import Foundation

// MARK: - Music domain models (additive, non-breaking)
//
// These value types model a music library's Artist → Album → Track hierarchy
// (plus flat Playlists and Genres). They are intentionally *separate* from
// `MediaItem`/`MediaItemKind`, which stay video-shaped (movie/series/episode):
// overloading those would force every existing `switch item.kind` in the video
// features to grow audio cases. Keeping music in its own types means video-only
// code paths are untouched.
//
// See `docs/music-library-proposal.md` and `MusicProvider.swift`.

/// The kind of a music-library node. Deliberately distinct from `MediaItemKind`
/// so the video model never has to learn about audio.
public enum MusicItemKind: String, Codable, Sendable, CaseIterable {
    case artist
    case album
    case track
    case playlist
    case genre
}

/// A recording artist (Jellyfin `MusicArtist`, Plex grandparent `artist`).
public struct MusicArtist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var artworkURL: URL?
    /// Number of albums by this artist, if the backend reports it.
    public var albumCount: Int?
    public var genres: [String]
    /// The owning `Account.id`, stamped by the aggregator when music from several
    /// providers is merged. `nil` for items returned directly by one provider.
    public var sourceAccountID: String?

    public init(
        id: String,
        name: String,
        artworkURL: URL? = nil,
        albumCount: Int? = nil,
        genres: [String] = [],
        sourceAccountID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artworkURL = artworkURL
        self.albumCount = albumCount
        self.genres = genres
        self.sourceAccountID = sourceAccountID
    }

    /// Returns a copy tagged as belonging to `accountID`.
    public func taggingSource(_ accountID: String) -> MusicArtist {
        var copy = self
        copy.sourceAccountID = accountID
        return copy
    }
}

/// An album (Jellyfin `MusicAlbum`, Plex parent `album`).
public struct MusicAlbum: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artistName: String?
    public var artistID: String?
    public var year: Int?
    public var artworkURL: URL?
    public var trackCount: Int?
    /// Total runtime of the album in seconds, if known.
    public var totalDuration: TimeInterval?
    public var genres: [String]
    public var sourceAccountID: String?

    public init(
        id: String,
        title: String,
        artistName: String? = nil,
        artistID: String? = nil,
        year: Int? = nil,
        artworkURL: URL? = nil,
        trackCount: Int? = nil,
        totalDuration: TimeInterval? = nil,
        genres: [String] = [],
        sourceAccountID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artistID = artistID
        self.year = year
        self.artworkURL = artworkURL
        self.trackCount = trackCount
        self.totalDuration = totalDuration
        self.genres = genres
        self.sourceAccountID = sourceAccountID
    }

    public func taggingSource(_ accountID: String) -> MusicAlbum {
        var copy = self
        copy.sourceAccountID = accountID
        return copy
    }
}

/// A single playable audio track (Jellyfin `Audio`, Plex leaf `track`).
public struct MusicTrack: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var albumTitle: String?
    public var albumID: String?
    public var artistName: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    /// Track runtime in seconds, if known.
    public var duration: TimeInterval?
    public var artworkURL: URL?
    public var sourceAccountID: String?

    public init(
        id: String,
        title: String,
        albumTitle: String? = nil,
        albumID: String? = nil,
        artistName: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval? = nil,
        artworkURL: URL? = nil,
        sourceAccountID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.albumTitle = albumTitle
        self.albumID = albumID
        self.artistName = artistName
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.artworkURL = artworkURL
        self.sourceAccountID = sourceAccountID
    }

    public func taggingSource(_ accountID: String) -> MusicTrack {
        var copy = self
        copy.sourceAccountID = accountID
        return copy
    }

    /// A human-friendly subtitle line, e.g. `Artist · Album`.
    public var subtitle: String? {
        switch (artistName, albumTitle) {
        case let (artist?, album?): return "\(artist) · \(album)"
        case let (artist?, nil): return artist
        case let (nil, album?): return album
        default: return nil
        }
    }
}

/// A user playlist of tracks.
public struct MusicPlaylist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artworkURL: URL?
    public var trackCount: Int?
    public var totalDuration: TimeInterval?
    public var sourceAccountID: String?

    public init(
        id: String,
        title: String,
        artworkURL: URL? = nil,
        trackCount: Int? = nil,
        totalDuration: TimeInterval? = nil,
        sourceAccountID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artworkURL = artworkURL
        self.trackCount = trackCount
        self.totalDuration = totalDuration
        self.sourceAccountID = sourceAccountID
    }

    public func taggingSource(_ accountID: String) -> MusicPlaylist {
        var copy = self
        copy.sourceAccountID = accountID
        return copy
    }
}

/// A music genre used to filter artists/albums.
public struct MusicGenre: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var sourceAccountID: String?

    public init(id: String, name: String, sourceAccountID: String? = nil) {
        self.id = id
        self.name = name
        self.sourceAccountID = sourceAccountID
    }

    public func taggingSource(_ accountID: String) -> MusicGenre {
        var copy = self
        copy.sourceAccountID = accountID
        return copy
    }
}
