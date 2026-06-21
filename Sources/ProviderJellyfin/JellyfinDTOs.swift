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
}

struct UserItemDataDto: Decodable {
    let PlaybackPositionTicks: Int64?
    let PlayedPercentage: Double?
    let Played: Bool?
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
    let Language: String?
    let DisplayTitle: String?
    let IsDefault: Bool?
    let IsForced: Bool?
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
