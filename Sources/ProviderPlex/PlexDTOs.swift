import Foundation

// MARK: - Plex API DTOs
//
// Minimal Codable mirrors of the Plex shapes Plozz consumes.
//
// Two JSON dialects are modelled here:
//  * **Plex Media Server** responses wrap everything in a `MediaContainer` and
//    use capitalised collection keys (`Metadata`, `Directory`, `Media`, `Part`,
//    `Stream`). Item fields are camelCase (`ratingKey`, `viewOffset`, …).
//  * **Plex.tv (plex.tv/api/v2)** PIN/resource/user responses are plain JSON
//    objects/arrays.
//
// Only fields Plozz actually uses are modelled; unknown fields are ignored.

// MARK: Server: MediaContainer envelopes

struct PlexMediaContainerResponse: Decodable {
    let MediaContainer: PlexMediaContainer
}

struct PlexMediaContainer: Decodable {
    let size: Int?
    let totalSize: Int?
    let offset: Int?
    let Metadata: [PlexMetadata]?
    let Directory: [PlexDirectory]?
}

/// A library section (`/library/sections`).
struct PlexDirectory: Decodable {
    let key: String?
    let title: String?
    let type: String?          // "movie", "show", "artist", "photo"
    let thumb: String?
    let art: String?
    let composite: String?
}

/// A media item: movie, show, season, episode, …
struct PlexMetadata: Decodable {
    let ratingKey: String?
    let key: String?
    let type: String?          // "movie", "show", "season", "episode", "clip"
    let title: String?
    let parentTitle: String?
    let grandparentTitle: String?
    let summary: String?
    let index: Int?            // episode number (or season index)
    let parentIndex: Int?      // season number for an episode
    let year: Int?
    let duration: Int?         // milliseconds
    let viewOffset: Int?       // milliseconds resumed-to
    let viewCount: Int?
    let thumb: String?
    let art: String?
    let grandparentThumb: String?
    let parentThumb: String?
    let Media: [PlexMedia]?
}

struct PlexMedia: Decodable {
    let id: Int?
    let duration: Int?
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let Part: [PlexPart]?
}

struct PlexPart: Decodable {
    let id: Int?
    let key: String?           // e.g. "/library/parts/123/16000/file.mkv"
    let duration: Int?
    let container: String?
    let Stream: [PlexStream]?
}

struct PlexStream: Decodable {
    let id: Int?
    let streamType: Int?       // 1 video, 2 audio, 3 subtitle
    let index: Int?
    let codec: String?
    let profile: String?
    let language: String?
    let languageTag: String?
    let displayTitle: String?
    let extendedDisplayTitle: String?
    let selected: Bool?
    let `default`: Bool?
    let forced: Bool?
    // Video facts
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let colorTrc: String?
    let DOVIPresent: Bool?
    // Audio facts
    let channels: Int?
    let samplingRate: Int?
    let audioChannelLayout: String?
    /// Per-stream bitrate, in **kbps** (Plex convention).
    let bitrate: Int?
}

// MARK: Plex.tv: PIN flow

/// `POST /api/v2/pins?strong=true` and `GET /api/v2/pins/{id}`.
struct PlexPinDTO: Decodable {
    let id: Int
    let code: String
    /// `nil`/empty until the user links the code at plex.tv/link.
    let authToken: String?
}

// MARK: Plex.tv: account user

/// `GET /api/v2/user`.
struct PlexUserDTO: Decodable {
    let id: Int?
    let uuid: String?
    let username: String?
    let title: String?
    let email: String?
}

// MARK: Plex.tv: resources (servers)

/// One device returned by `GET /api/v2/resources`. Plozz only cares about those
/// that `provides` "server".
struct PlexResourceDTO: Decodable {
    let name: String?
    let product: String?
    let clientIdentifier: String?
    let provides: String?
    let accessToken: String?
    let owned: Bool?
    let connections: [PlexConnectionDTO]?
}

/// A single way to reach a server. `local`/`relay` drive connection preference;
/// `uri` is the ready-to-use base URL.
struct PlexConnectionDTO: Decodable {
    let `protocol`: String?
    let address: String?
    let port: Int?
    let uri: String?
    let local: Bool?
    let relay: Bool?
    let IPv6: Bool?
}

// MARK: - Time helpers

enum PlexTime {
    /// Plex expresses durations/offsets in milliseconds.
    static func seconds(fromMilliseconds ms: Int?) -> TimeInterval? {
        guard let ms else { return nil }
        return TimeInterval(ms) / 1000.0
    }

    static func milliseconds(fromSeconds seconds: TimeInterval) -> Int {
        Int((seconds * 1000.0).rounded())
    }
}
