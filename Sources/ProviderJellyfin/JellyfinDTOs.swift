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

// MARK: Media segments

/// `GET /MediaSegments/{itemId}` response envelope. Each item is a structural
/// segment (intro, outro, recap, …) the server detected. Times are 100-ns ticks.
struct MediaSegmentsResponse: Decodable {
    let Items: [MediaSegmentDto]?
}

struct MediaSegmentDto: Decodable {
    let Id: String?
    let segmentType: String?
    let StartTicks: Int64?
    let EndTicks: Int64?

    private enum CodingKeys: String, CodingKey {
        case Id
        case segmentType = "Type"
        case StartTicks
        case EndTicks
    }
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

struct ThemeMediaResponse: Decodable {
    let ThemeSongsResult: ItemsResponse?
}

struct UserViewsResponse: Decodable {
    let Items: [BaseItemDto]
}

struct ChapterInfoDto: Decodable {
    let StartPositionTicks: Int64?
    let MarkerType: String?
}

struct BaseItemDto: Decodable {
    let Id: String
    let Name: String?
    /// The original-language title (Jellyfin's `OriginalTitle`), present when it
    /// differs from the localised `Name`. Requested via `Fields=OriginalTitle`.
    let OriginalTitle: String?
    let `Type`: String?
    let CollectionType: String?
    let Overview: String?
    let SeriesName: String?
    let SeasonName: String?
    let SeriesId: String?
    let SeasonId: String?
    let ParentId: String?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let ProductionYear: Int?
    let RunTimeTicks: Int64?
    let OfficialRating: String?
    let CommunityRating: Double?
    let CriticRating: Double?
    let ProviderIds: [String: String]?
    /// Cast & crew. Present only when `People` is requested in `Fields`. Each
    /// entry is an actor/director/writer/etc.; for anime the `Actor` entries are
    /// the voice cast with `Role` holding the character voiced.
    let People: [BaseItemPersonDto]?
    /// Production studios (e.g. `MAPPA`, `Wit Studio`). Present only when
    /// `Studios` is requested in `Fields`.
    let Studios: [NamedReferenceDto]?
    /// Free-form tags the server/metadata provider attached (e.g. `Isekai`,
    /// `Shounen`). Present only when `Tags` is requested in `Fields`.
    let Tags: [String]?
    /// Short marketing taglines. Present only when `Taglines` is requested in
    /// `Fields`.
    let Taglines: [String]?
    let UserData: UserItemDataDto?
    let MediaSources: [MediaSourceInfo]?
    let MediaStreams: [MediaStreamDto]?
    let ImageTags: [String: String]?
    let BackdropImageTags: [String]?
    /// Emby exposes intro and credits markers as chapter entries.
    let Chapters: [ChapterInfoDto]?
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
    /// Online trailer links the server resolved from its own metadata provider
    /// (e.g. YouTube watch URLs). Present only when `RemoteTrailers` is requested
    /// in `Fields`. These let Plozz surface official trailers with no client-side
    /// metadata key — the key lives on the user's own server.
    let RemoteTrailers: [MediaUrlDto]?
}

/// A named external media link from `BaseItemDto.RemoteTrailers` — typically a
/// YouTube watch URL for an official trailer.
struct MediaUrlDto: Decodable {
    let Url: String?
    let Name: String?
}

/// A Jellyfin `{ Name, Id }` reference pair (used for artists, genres, …).
struct NameGuidPairDto: Decodable {
    let Name: String?
    let Id: String?
}

/// A named reference whose identifier is intentionally ignored. Jellyfin emits
/// studio ids as GUID strings, while Emby defines `Studios` as `NameLongIdPair`
/// with integer ids. Plozz only displays the studio name, so decoding just that
/// shared field preserves both schemas without weakening artist-id typing.
struct NamedReferenceDto: Decodable {
    let Name: String?
}

/// One cast/crew member from `BaseItemDto.People`. `Type` is the role kind
/// (`Actor`, `GuestStar`, `Director`, `Writer`, `Producer`, …) and `Role` is the
/// character name for actors (the voiced character, for anime). `PrimaryImageTag`
/// is present only when the person has a headshot on the server.
struct BaseItemPersonDto: Decodable {
    let Id: String?
    let Name: String?
    let Role: String?
    let `Type`: String?
    let PrimaryImageTag: String?
}

struct UserItemDataDto: Decodable {
    let PlaybackPositionTicks: Int64?
    let PlayedPercentage: Double?
    let Played: Bool?
    /// Whether the user has favourited the item — surfaced as the unified
    /// Watchlist state.
    let IsFavorite: Bool?
    /// ISO-8601 timestamp of the user's last playback, used as the
    /// most-recent-wins tiebreaker when unifying watch-state across servers.
    let LastPlayedDate: String?
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
    /// Human-readable source name, e.g. `Movie (2009) Bluray-2160p`. Surfaced in
    /// the version picker when a title has several sources.
    let Name: String?
    /// Server filesystem path of the selected source, when Jellyfin exposes it.
    /// Used only for its basename in diagnostics; the full path is never shown.
    let Path: String?
    /// File size in bytes, used to show "12.4 GB" per version.
    let Size: Int64?
    /// Overall declared bitrate in bits/sec.
    let Bitrate: Int?
    /// Per-source runtime in 100-nanosecond ticks.
    let RunTimeTicks: Int64?
    let MediaStreams: [MediaStreamDto]?
    /// Why the server chose to transcode this source rather than direct-play it
    /// (e.g. `["SubtitleCodecNotSupported"]`, `["VideoRangeTypeNotSupported"]`,
    /// `["AudioChannelsNotSupported"]`). Empty/absent when direct-playing. We log
    /// this so "why did Jellyfin transcode?" is answerable from device logs.
    let TranscodeReasons: [String]?
}

/// Body of `POST /Items/{id}/PlaybackInfo`. Carrying a `DeviceProfile` is what
/// lets the server choose DirectPlay vs a seekable HLS transcode for this device.
struct PlaybackInfoBody: Encodable {
    let UserId: String
    let MaxStreamingBitrate: Int
    let AutoOpenLiveStream: Bool
    let MediaSourceId: String?
    let EnableDirectPlay: Bool?
    let EnableDirectStream: Bool?
    let EnableTranscoding: Bool
    let DeviceProfile: JellyfinCapabilityProfile
}

struct MediaStreamDto: Decodable {
    let Index: Int
    let `Type`: String       // "Audio", "Subtitle", "Video"
    let Codec: String?
    /// Container codec FourCC (`codec_tag_string`), e.g. `hvc1`/`hev1` for HEVC.
    let CodecTag: String?
    let Profile: String?
    let IsInterlaced: Bool?
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
    /// Emby's authoritative HDR classification. Jellyfin uses `VideoRangeType`;
    /// Emby instead emits `Hdr10`, `Hdr10Plus`, `HyperLogGamma`, or
    /// `DolbyVision` here and may leave the coarse `VideoRange` as `SDR`.
    let ExtendedVideoType: String?
    let ExtendedVideoSubType: String?
    let ExtendedVideoSubTypeDescription: String?
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

/// Encodes dates for Jellyfin request bodies (e.g. `UserData.LastPlayedDate`).
/// Jellyfin accepts ISO 8601 with a `Z` zone; we emit fractional seconds to match
/// the server's own `DateTime` precision. Kept separate from the *decoding*
/// formatters in `JellyfinProvider` (which must also tolerate .NET 7-digit
/// fractional seconds) because encoding only needs one canonical form.
enum JellyfinDate {
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func iso8601(from date: Date) -> String {
        iso8601.string(from: date)
    }
}

// MARK: - Lyrics

/// `GET /Audio/{itemId}/Lyrics` response. `Lyrics` carries one entry per line;
/// `Start` (when present) is the line's offset in 100ns ticks. Plain-text
/// lyrics omit `Start`.
struct LyricDto: Decodable {
    let Lyrics: [LyricLineDto]?
}

struct LyricLineDto: Decodable {
    let Text: String?
    let Start: Int64?
}
