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

/// Decodes an integer that Plex serializes as a **number** on the per-server
/// (PMS) API but as a **string** on the plex.tv Discover service (e.g. the
/// watchlist's `Media`/`Part`/`Stream` ids are global string ids). Tolerating
/// both keeps one string id from aborting the decode of an entire payload; a
/// non-numeric string decodes to `nil` (those ids don't resolve against a PMS
/// anyway, so nothing downstream is lost).
@propertyWrapper
struct LenientInt: Decodable {
    var wrappedValue: Int?
    init(wrappedValue: Int?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            wrappedValue = i
        } else if let s = try? c.decode(String.self) {
            wrappedValue = Int(s)
        } else {
            wrappedValue = nil
        }
    }
}

extension KeyedDecodingContainer {
    // Synthesized Decodable calls `decode(_:forKey:)` for a wrapped property, so a
    // missing key would throw; default it to an empty value instead.
    func decode(_ type: LenientInt.Type, forKey key: Key) throws -> LenientInt {
        (try? decodeIfPresent(LenientInt.self, forKey: key)) ?? LenientInt(wrappedValue: nil)
    }
}

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
    /// Per-library promoted "hubs" (`/hubs/sections/{id}`): Recently Added, On
    /// Deck, "More in <Genre>", "Because you watched…", Top Rated, … Present only
    /// on hub responses; nil elsewhere.
    let Hub: [PlexHub]?
}

/// One promoted row from `/hubs/sections/{sectionID}` (or the global `/hubs`).
///
/// Plozz surfaces these as a library's *discovery* rows in unmerged Home mode.
/// Only the fields needed to build a `LibrarySection` and to identify/deduplicate
/// a hub against the uniform base rows are modelled; unknown fields are ignored.
struct PlexHub: Decodable {
    /// Stable, machine identifier for the hub, e.g. `"movie.recentlyadded.1"`,
    /// `"movie.genre.<id>"`, `"movie.similar.<id>"`, `"tv.startWatching"`. Used
    /// both as the `LibrarySection.id` and to filter out hubs that duplicate the
    /// base rows — matched on this stable value, never the localised `title`.
    let hubIdentifier: String?
    /// The hub's rendering context, e.g. `"hub.movie.recentlyadded"`,
    /// `"hub.movie.genre"`. A secondary, equally-stable signal for deduplication.
    let context: String?
    /// Display heading, already humanised by Plex ("Recently Added Movies",
    /// "More in Drama", "Because you watched Inception").
    let title: String?
    /// The hub's item type ("movie", "show", "episode", "clip", "mixed", …).
    let type: String?
    /// Whether more items exist beyond those inlined here.
    let more: Bool?
    /// The hub's items. Some hubs return `Directory` entries (e.g. genre folders)
    /// instead of playable `Metadata`; those are ignored (we only surface playable
    /// content rows).
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
    /// Number of items in this grouping — present on facet listings such as
    /// `/library/sections/{id}/firstCharacter` (count of titles under a letter).
    let size: Int?
    /// The grouping's sort value — the first character (`"A"`…`"Z"`, `"#"`,
    /// `"1-9"`, …) on the `firstCharacter` facet.
    let titleSort: String?
}

/// A media item: movie, show, season, episode, …
struct PlexMetadata: Decodable {
    let ratingKey: String?
    let key: String?
    /// The owning library section's numeric id (present on hub/onDeck/
    /// recentlyAdded item feeds). Equals the `/library/sections` `key`, so
    /// stringified it matches `MediaLibrary.id` and lets Home suppress an item
    /// whose library the user hid. Absent on surfaces that don't report it
    /// (e.g. account-level Watchlist) — then the item stays fail-open.
    let librarySectionID: Int?
    /// The item's canonical **global** Plex guid (`plex://movie/<id>`,
    /// `plex://show/<id>`, …) — distinct from the per-server `ratingKey`. The
    /// account-level Watchlist (Discover) service keys on this, so it's stashed
    /// into `providerIDs["PlexGuid"]` during mapping.
    let guid: String?
    let type: String?          // "movie", "show", "season", "episode", "clip"
    /// For extras/clips, the kind of extra, e.g. "trailer", "behindTheScenes".
    let subtype: String?
    let title: String?
    /// Original-language title (`originalTitle`), present when distinct from the
    /// localised `title`. Used as an extra cross-server discovery query.
    let originalTitle: String?
    let parentTitle: String?
    let grandparentTitle: String?
    /// For an episode, the ratingKey of its season (parent) and series
    /// (grandparent) — used to offer "Go to Season" / "Go to Series" jumps.
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let summary: String?
    /// Short marketing tagline (Plex records a single `tagline` attribute on
    /// movies/shows). Mapped into `MediaItem.taglines` for parity with Jellyfin,
    /// and used as the hero's punchy one-liner.
    let tagline: String?
    let index: Int?            // episode number (or season index)
    let parentIndex: Int?      // season number for an episode
    let year: Int?
    let duration: Int?         // milliseconds
    let viewOffset: Int?       // milliseconds resumed-to
    let viewCount: Int?
    /// Number of watched episodes rolled up onto a series.
    let viewedLeafCount: Int?
    /// Epoch-seconds timestamp of the user's last playback, used as the
    /// most-recent-wins tiebreaker when unifying watch-state across servers.
    let lastViewedAt: Int?
    /// The explicit edition / cut Plex records for the item (e.g. "Director's
    /// Cut", "Theatrical"). Surfaced as `MediaVersion.edition`, taking precedence
    /// over anything parsed from a file name.
    let editionTitle: String?
    let thumb: String?
    let art: String?
    /// Server-relative path to this title's theme audio.
    let theme: String?
    let grandparentThumb: String?
    let parentThumb: String?
    /// Series episode count or album/playlist track count (`leafCount`) and artist album count
    /// (`childCount`) — used to populate music nodes' counts.
    let leafCount: Int?
    let childCount: Int?
    /// Composite mosaic art for a playlist (`/playlists/{id}/composite/...`),
    /// used as the playlist's artwork when it has no single cover.
    let composite: String?
    /// Release year of an album reached via a track (`parentYear`), used as a
    /// fallback when the album node itself omits `year`.
    let parentYear: Int?
    /// Content certificate, e.g. `TV-14`, `PG-13`, `R`.
    let contentRating: String?
    /// Critic score (0–10 on Plex's normalised scale); `ratingImage` names the
    /// source, e.g. `rottentomatoes://image.rating.ripe` or `imdb://…`.
    let rating: Double?
    let ratingImage: String?
    /// Audience score (0–10); `audienceRatingImage` names the source.
    let audienceRating: Double?
    let audienceRatingImage: String?
    /// The **full** set of critic/audience scores the new Plex Movie agent
    /// records — IMDb, Rotten Tomatoes (critic + audience) and The Movie
    /// Database — as opposed to the two `rating`/`audienceRating` scalars above,
    /// which only carry the single "primary" pair Plex picks. Each entry names
    /// its source + variant in `image` (`imdb://image.rating`,
    /// `rottentomatoes://image.rating.ripe`, `themoviedb://image.rating`) and
    /// its `type` (`critic`/`audience`); values are on Plex's normalised 0–10
    /// scale. Present on the item-detail metadata for library items scanned with
    /// the Plex Movie agent.
    let Rating: [PlexRating]?
    /// External ids (`imdb://...`, `tmdb://...`, `tvdb://...`, `anidb://...`)
    /// exported by Plex agents/scanners. Ingested into `MediaItem.providerIDs`
    /// so the metadata router can match items by a stable external id (which
    /// also sharpens anime detection) instead of a fuzzy title search.
    let Guid: [PlexGuid]?
    let Genre: [PlexTag]?
    /// Freeform keyword tags (`<Tag tag="…"/>`), when the agent records any.
    /// Mapped to `MediaItem.tags` for parity with Jellyfin.
    let Tag: [PlexTag]?
    /// Cast (`<Role>` — actors, with character `role` and a headshot `thumb`).
    let Role: [PlexRole]?
    /// Crew elements Plex records as people with the same shape as `Role`
    /// (an `id`, a person `tag` name and an optional `thumb`).
    let Director: [PlexRole]?
    let Writer: [PlexRole]?
    /// Production company (Plex records a single `studio` attribute, not a list).
    let studio: String?
    let Media: [PlexMedia]?
    /// Image variants Plex records for the item (`type` one of `coverPoster`,
    /// `background`, `clearLogo`, `snapshot`, …). The full metadata fetch returns
    /// this array; we read the `clearLogo` entry for the hero/detail title logo,
    /// which Plex does NOT expose via the top-level `thumb`/`art` attributes.
    let Image: [PlexImage]?
    /// Plex Pass intro/credits markers, present only when the metadata request
    /// passes `includeMarkers=1`. Offsets are in milliseconds.
    let Marker: [PlexMarker]?
}

/// One entry from a Plex item's `Image` array. `type` names the variant
/// (`coverPoster`, `background`, `clearLogo`, `snapshot`, …) and `url` is either
/// a server-relative path (`/library/metadata/…/clearLogo/…`) or an absolute
/// `metadata-static.plex.tv` URL. Decoded leniently since Plex omits fields it
/// has no value for.
struct PlexImage: Decodable {
    let alt: String?
    let type: String?
    let url: String?

    private enum CodingKeys: String, CodingKey { case alt, type, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alt = c.flexibleString(.alt)
        type = c.flexibleString(.type)
        url = c.flexibleString(.url)
    }
}

/// One Plex external-id GUID, e.g. `{ "id": "imdb://tt0111161" }`.
struct PlexGuid: Decodable {
    let id: String?
}

/// One entry from a Plex item's `Rating` array (the full multi-source score set;
/// see ``PlexMetadata/Rating``). `image` names the source and, for Rotten
/// Tomatoes, its fresh/rotten variant (`…ripe`/`…rotten` for critic,
/// `…upright`/`…spilled` for audience); `type` is `critic` or `audience`;
/// `value` is on Plex's normalised 0–10 scale. Decoded leniently because Plex
/// serialises `value` as a number or string depending on server version.
struct PlexRating: Decodable {
    let image: String?
    let value: Double?
    let type: String?

    private enum CodingKeys: String, CodingKey { case image, value, type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        image = c.flexibleString(.image)
        value = c.flexibleDouble(.value)
        type = c.flexibleString(.type)
    }
}

/// A simple Plex tag element (genres, directors, …): only the display `tag` is
/// used.
struct PlexTag: Decodable {
    let tag: String?
}

/// A Plex person element (`<Role>`, `<Director>`, `<Writer>`): an actor or crew
/// member. `tag` is the person's name, `role` the character (cast only) and
/// `thumb` a headshot (a server path or an absolute metadata-static URL).
/// Decoded leniently because Plex serialises `id` as a number or string
/// depending on server version.
struct PlexRole: Decodable {
    let id: Int?
    let tag: String?
    let role: String?
    let thumb: String?

    private enum CodingKeys: String, CodingKey {
        case id, tag, role, thumb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id)
        tag = c.flexibleString(.tag)
        role = c.flexibleString(.role)
        thumb = c.flexibleString(.thumb)
    }
}

struct PlexMedia: Decodable {
    @LenientInt var id: Int?
    let duration: Int?
    /// Plex reports this media-level value in kilobits per second.
    let bitrate: Int?
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    /// Media-level facts Plex includes even in list/children responses (where
    /// the per-stream `Stream` array may be omitted): a coarse resolution token
    /// (`4k`, `1080`, `720`, `sd`), pixel dimensions and the audio channel
    /// count. Used as a fallback so episode rails still earn resolution/audio
    /// badges without a full per-item metadata fetch.
    let videoResolution: String?
    let width: Int?
    let height: Int?
    let audioChannels: Int?
    let videoProfile: String?
    /// Media-level audio profile summary, e.g. `dolby digital plus + dolby atmos`.
    /// Plex signals Atmos here even when the per-audio-stream `profile`/`displayTitle`
    /// don't mention it, so this is the canonical place to detect Atmos for many
    /// PMS endpoints.
    let audioProfile: String?
    /// Human-friendly video stream summary, e.g. `4K DoVi/HDR10 (HEVC Main 10)`.
    /// Present even when the detailed `Part.Stream` array is omitted.
    let videoStreamDisplayTitle: String?
    let Part: [PlexPart]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id)
        duration = c.flexibleInt(.duration)
        bitrate = c.flexibleInt(.bitrate)
        container = c.flexibleString(.container)
        videoCodec = c.flexibleString(.videoCodec)
        audioCodec = c.flexibleString(.audioCodec)
        videoResolution = c.flexibleString(.videoResolution)
        width = c.flexibleInt(.width)
        height = c.flexibleInt(.height)
        audioChannels = c.flexibleInt(.audioChannels)
        videoProfile = c.flexibleString(.videoProfile)
        audioProfile = c.flexibleString(.audioProfile)
        videoStreamDisplayTitle = c.flexibleString(.videoStreamDisplayTitle)
        Part = try c.decodeIfPresent([PlexPart].self, forKey: .Part)
    }

    private enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, container, videoCodec, audioCodec, videoResolution
        case width, height, audioChannels, videoProfile, audioProfile, videoStreamDisplayTitle, Part
    }
}

/// A Plex Pass structural marker (`<Marker type="intro|credits" ...>`). Offsets
/// are milliseconds from the start of the item. Decoded flexibly because Plex
/// occasionally serialises numeric attributes as strings.
struct PlexMarker: Decodable {
    let type: String?
    let startTimeOffset: Int?
    let endTimeOffset: Int?

    private enum CodingKeys: String, CodingKey {
        case type, startTimeOffset, endTimeOffset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.flexibleString(.type)
        startTimeOffset = c.flexibleInt(.startTimeOffset)
        endTimeOffset = c.flexibleInt(.endTimeOffset)
    }
}

struct PlexPart: Decodable {
    @LenientInt var id: Int?
    let key: String?           // e.g. "/library/parts/123/16000/file.mkv"
    /// Absolute filesystem path of the file, e.g.
    /// `/data/Movies/Movie (2009)/Movie (2009) Extended Bluray-2160p.mkv`. Its
    /// basename is the release name we parse for the source quality (Remux /
    /// BluRay / WEB-DL) and, as a fallback, the edition.
    let file: String?
    let size: Int64?
    let duration: Int?
    let container: String?
    /// Which trickplay (BIF) index resolutions the server has generated for this
    /// part, e.g. `"sd"` or `"sd,hd"`. Present only when the server has built
    /// "video preview thumbnails"; drives Plozz's scrubbing previews.
    let indexes: String?
    let Stream: [PlexStream]?
}

struct PlexStream: Decodable {
    @LenientInt var id: Int?
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
    /// Server-relative key for an external/sidecar subtitle file (e.g.
    /// `/library/streams/12345`). Present for external subs; `nil` for embedded
    /// streams. Used to deliver the subtitle text to the player.
    let key: String?
    // Video facts
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let scanType: String?
    let colorTrc: String?
    let DOVIPresent: Bool?
    /// Dolby Vision profile number (Plex reports it as a JSON number, same as
    /// `width`/`height`). Apple TV can decode only single-layer **Profile 5** and
    /// **Profile 8**; Profile 7 (and any unknown profile) must transcode.
    let DOVIProfile: Int?
    let DOVILevel: Int?
    let DOVIBLPresent: Bool?
    /// Dolby Vision base-layer **compatibility** ID — the authoritative cross-
    /// compat signal (0 = none / pure DV like Profile 5, 1 = HDR10, 2 = SDR,
    /// 4 = HLG). `DOVIBLPresent` only says a base layer exists (it always does for
    /// single-layer DV); it does NOT imply an HDR10 fallback.
    let DOVIBLCompatID: Int?
    // Audio facts
    let channels: Int?
    let samplingRate: Int?
    let audioChannelLayout: String?
    /// Per-stream bitrate, in **kbps** (Plex convention).
    let bitrate: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexibleInt(.id)
        streamType = c.flexibleInt(.streamType)
        index = c.flexibleInt(.index)
        codec = c.flexibleString(.codec)
        profile = c.flexibleString(.profile)
        language = c.flexibleString(.language)
        languageTag = c.flexibleString(.languageTag)
        displayTitle = c.flexibleString(.displayTitle)
        extendedDisplayTitle = c.flexibleString(.extendedDisplayTitle)
        selected = c.flexibleBool(.selected)
        `default` = c.flexibleBool(.default)
        forced = c.flexibleBool(.forced)
        key = c.flexibleString(.key)
        width = c.flexibleInt(.width)
        height = c.flexibleInt(.height)
        frameRate = c.flexibleDouble(.frameRate)
        scanType = c.flexibleString(.scanType)
        colorTrc = c.flexibleString(.colorTrc)
        DOVIPresent = c.flexibleBool(.DOVIPresent)
        DOVIProfile = c.flexibleInt(.DOVIProfile)
        DOVILevel = c.flexibleInt(.DOVILevel)
        DOVIBLPresent = c.flexibleBool(.DOVIBLPresent)
        DOVIBLCompatID = c.flexibleInt(.DOVIBLCompatID)
        channels = c.flexibleInt(.channels)
        samplingRate = c.flexibleInt(.samplingRate)
        audioChannelLayout = c.flexibleString(.audioChannelLayout)
        bitrate = c.flexibleInt(.bitrate)
    }

    private enum CodingKeys: String, CodingKey {
        case id, streamType, index, codec, profile, language, languageTag
        case displayTitle, extendedDisplayTitle, selected, `default`, forced, key
        case width, height, frameRate, scanType, colorTrc
        case DOVIPresent, DOVIProfile, DOVILevel, DOVIBLPresent, DOVIBLCompatID
        case channels, samplingRate, audioChannelLayout, bitrate
    }
}

// MARK: - On-demand subtitle search

/// Response envelope for `GET /library/metadata/{ratingKey}/subtitles` — Plex's
/// on-demand subtitle search. Unlike an item's *attached* streams (which arrive
/// nested under `Metadata → Media → Part → Stream`), the search returns its
/// candidate subtitles as `Stream` elements at the **`MediaContainer` root**, so
/// this dedicated envelope decodes that top-level `Stream` array.
struct PlexSubtitleSearchResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        let Stream: [PlexSubtitleSearchStream]?
    }
}

/// One on-demand subtitle search result. Distinct from `PlexStream` (which models
/// an item's embedded/attached streams): search results carry the download `key`
/// (echoed back verbatim as `?key=` to the download PUT), the source provider,
/// a match/popularity `score`, and the HI/forced flags that drive accessibility
/// ranking. Numeric/boolean fields use the lenient decoders because PMS serialises
/// them inconsistently (JSON number vs string vs bool).
struct PlexSubtitleSearchStream: Decodable {
    let key: String?
    let title: String?
    let language: String?
    let languageCode: String?
    let format: String?
    let providerTitle: String?
    let score: Int?
    let forced: Bool?
    let hearingImpaired: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.flexibleString(.key)
        title = c.flexibleString(.title)
        language = c.flexibleString(.language)
        languageCode = c.flexibleString(.languageCode)
        format = c.flexibleString(.format)
        providerTitle = c.flexibleString(.providerTitle)
        score = c.flexibleInt(.score)
        forced = c.flexibleBool(.forced)
        hearingImpaired = c.flexibleBool(.hearingImpaired)
    }

    private enum CodingKeys: String, CodingKey {
        case key, title, language, languageCode, format, providerTitle, score, forced, hearingImpaired
    }
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
    let thumb: String?
}

// MARK: Plex.tv: Home users

/// `GET /api/v2/home/users` — wrapper around the Home's user list.
struct PlexHomeUsersDTO: Decodable {
    let users: [PlexHomeUserDTO]
}

/// One Plex Home user. `protected`/`hasPassword` mean a PIN is needed to switch.
struct PlexHomeUserDTO: Decodable {
    let id: Int?
    let uuid: String?
    let title: String?
    let username: String?
    let admin: Bool?
    let restricted: Bool?
    let protected: Bool?
    let hasPassword: Bool?
    let thumb: String?
}

/// `POST /api/v2/home/users/{uuid}/switch` — returns the switched-to user,
/// carrying that user's auth token (key spelling varies by API surface).
struct PlexHomeSwitchDTO: Decodable {
    let authToken: String?
    let authenticationToken: String?
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

// MARK: - Lenient scalar decoding

// Plex Media Server's JSON serialises XML attributes inconsistently: numeric and
// boolean-ish fields can arrive as JSON numbers (`"DOVIPresent": 1`), JSON
// strings (`"DOVIProfile": "8"`) **or** JSON booleans depending on the field,
// server version and codepath. A plain synthesised `Decodable` declares these as
// `Bool?`/`Int?` and **throws** a type mismatch when the representation differs —
// which discards the entire stream (and, cascading up, the whole metadata item),
// silently dropping a 4K Dolby Vision file to a coarse/empty badge set. These
// helpers accept any of the representations so a single quirky field can never
// nuke an item's technical badges.
private extension KeyedDecodingContainer {
    func flexibleBool(_ key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        if let value = try? decode(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func flexibleInt(_ key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        if let value = try? decode(Double.self, forKey: key) { return Int(value) }
        return nil
    }

    func flexibleDouble(_ key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func flexibleString(_ key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }
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
