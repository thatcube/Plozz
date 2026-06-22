import Foundation

// MARK: - Jellyfin API DTOs
//
// Minimal Codable mirrors of the Jellyfin REST shapes Plozz consumes. Field
// names match Jellyfin's PascalCase JSON. Only fields we actually use are
// modelled; unknown fields are ignored by the decoder.

struct PublicSystemInfo: Decodable {
    let Id: String?
    let ServerName: String?
    let Version: String?
    let ProductName: String?
}

struct QuickConnectResultDTO: Decodable {
    let Authenticated: Bool
    let Secret: String
    let Code: String
}

struct AuthenticationResultDTO: Decodable {
    let AccessToken: String
    let ServerId: String?
    let User: UserDTO
}

struct UserDTO: Decodable {
    let Id: String
    let Name: String
}

struct AuthenticateWithQuickConnectBody: Encodable {
    let Secret: String
}

struct AuthenticateByNameBody: Encodable {
    let Username: String
    let Pw: String
}

struct ItemsResponse: Decodable {
    let Items: [BaseItemDto]
    let TotalRecordCount: Int?
}

struct UserViewsResponse: Decodable {
    let Items: [BaseItemDto]
}

struct BaseItemDto: Decodable {
    let Id: String
    let Name: String?
    let `Type`: String?
    let CollectionType: String?
    let Overview: String?
    let SeriesName: String?
    let SeasonName: String?
    /// For an episode, the id of its parent series (used to fall back to series
    /// artwork when the episode itself has no image).
    let SeriesId: String?
    /// For an episode, the id of its parent season (used to offer a "Go to
    /// Season" jump from cards shown outside the season's own list).
    let SeasonId: String?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let ProductionYear: Int?
    let RunTimeTicks: Int64?
    let CommunityRating: Double?
    let CriticRating: Double?
    let ProviderIds: [String: String]?
    let UserData: UserItemDataDto?
    let MediaSources: [MediaSourceInfo]?
    let MediaStreams: [MediaStreamDto]?
    let ImageTags: [String: String]?
    let BackdropImageTags: [String]?
    /// Trickplay (scrubbing-thumbnail) manifests, keyed by media-source id then
    /// by thumbnail width. Present only when `Trickplay` is requested in `Fields`
    /// and the server has generated trickplay images for the item.
    let Trickplay: [String: [String: TrickplayInfoDto]]?

    // MARK: Music fields (additive, all optional)
    //
    // Present on `MusicArtist`/`MusicAlbum`/`Audio`/`Playlist`/`MusicGenre`
    // responses; absent (and ignored) for video items.
    /// The album title an `Audio` track belongs to.
    let Album: String?
    /// The id of the album an `Audio` track belongs to.
    let AlbumId: String?
    /// The primary album artist (for an album or a track).
    let AlbumArtist: String?
    /// The id of the album's primary artist, when reported via `AlbumArtists`.
    let AlbumArtists: [NameGuidPairDto]?
    /// Performing artists for a track/album.
    let Artists: [String]?
    /// Artist items with ids, used to link a track/album back to its artist.
    let ArtistItems: [NameGuidPairDto]?
    /// Genre names for an artist/album/track.
    let Genres: [String]?
    /// Number of children (e.g. albums for an artist, tracks for an album).
    let ChildCount: Int?
}

/// A Jellyfin `{ Name, Id }` reference pair (used for artists, genres, …).
struct NameGuidPairDto: Decodable {
    let Name: String?
    let Id: String?
}

struct UserItemDataDto: Decodable {
    let PlaybackPositionTicks: Int64?
    let PlayedPercentage: Double?
    let Played: Bool?
}

/// Jellyfin trickplay tile-group metadata (`BaseItemDto.Trickplay[srcId][width]`).
/// Geometry for the pre-generated scrubbing thumbnails: each tile image packs
/// `TileWidth × TileHeight` thumbnails of `Width × Height` px, one thumbnail per
/// `Interval` ms.
struct TrickplayInfoDto: Decodable {
    let Width: Int?
    let Height: Int?
    let TileWidth: Int?
    let TileHeight: Int?
    let ThumbnailCount: Int?
    let Interval: Int?
    let Bandwidth: Int?
}

struct PlaybackInfoResponse: Decodable {
    let MediaSources: [MediaSourceInfo]
    let PlaySessionId: String?
}

struct MediaSourceInfo: Decodable {
    let Id: String?
    let ETag: String?
    let TranscodingUrl: String?
    let TranscodingSubProtocol: String?
    let SupportsDirectPlay: Bool?
    let SupportsDirectStream: Bool?
    let SupportsTranscoding: Bool?
    let Container: String?
    let MediaStreams: [MediaStreamDto]?
}

/// Body of `POST /Items/{id}/PlaybackInfo`. Carrying a `DeviceProfile` is what
/// lets the server choose DirectPlay vs a seekable HLS transcode for this device.
struct PlaybackInfoBody: Encodable {
    let UserId: String
    let MaxStreamingBitrate: Int
    let AutoOpenLiveStream: Bool
    let DeviceProfile: JellyfinCapabilityProfile
}

struct MediaStreamDto: Decodable {
    let Index: Int
    let `Type`: String       // "Audio", "Subtitle", "Video"
    let Codec: String?
    /// Container codec FourCC (`codec_tag_string`), e.g. `hvc1`/`hev1` for HEVC.
    let CodecTag: String?
    let Profile: String?
    let Language: String?
    let DisplayTitle: String?
    let IsDefault: Bool?
    let IsForced: Bool?
    /// Whether this subtitle stream is text-based (SRT/ASS/embedded text) and so
    /// can be delivered/converted to WebVTT for the player. Image-based subs
    /// (PGS/VOBSUB) report `false` and need server burn-in instead.
    let IsTextSubtitleStream: Bool?
    let IsExternal: Bool?
    // Video facts
    let Width: Int?
    let Height: Int?
    let BitDepth: Int?
    let BitRate: Int?
    let RealFrameRate: Double?
    let AverageFrameRate: Double?
    let VideoRange: String?
    let VideoRangeType: String?
    let ColorTransfer: String?
    // Audio facts
    let Channels: Int?
    let SampleRate: Int?
    let ChannelLayout: String?
}

/// One result from `GET /Items/{id}/RemoteSearch/Subtitles/{language}`.
struct RemoteSubtitleInfoDto: Decodable {
    let Id: String?
    let Name: String?
    let ProviderName: String?
    let ThreeLetterISOLanguageName: String?
    let Format: String?
    let CommunityRating: Double?
    let DownloadCount: Int?
    let IsForced: Bool?
    let IsHashMatch: Bool?
}

// MARK: - Ticks helpers

enum JellyfinTicks {
    /// Jellyfin expresses time in 100-nanosecond "ticks".
    static let perSecond: Int64 = 10_000_000

    static func seconds(fromTicks ticks: Int64?) -> TimeInterval? {
        guard let ticks else { return nil }
        return TimeInterval(ticks) / TimeInterval(perSecond)
    }

    static func ticks(fromSeconds seconds: TimeInterval) -> Int64 {
        Int64(seconds * TimeInterval(perSecond))
    }
}
