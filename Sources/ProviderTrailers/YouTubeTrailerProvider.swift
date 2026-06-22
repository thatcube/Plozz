import Foundation
import CoreModels
import YouTubeKit

/// A synthetic ``MediaProvider`` that plays an online trailer by extracting a
/// natively-playable stream from its YouTube video id.
///
/// Online trailers (sourced from TMDb) have no backing server item, so they
/// can't be resolved by an account's provider. This provider bridges that gap:
/// the player is built with `itemID` set to the YouTube video id, and
/// ``playbackInfo(for:)`` uses YouTubeKit to resolve a progressive stream URL
/// (video+audio, natively decodable) which it hands back as an ordinary
/// `PlaybackRequest`. This is the same technique Infuse uses — playing the raw
/// stream directly with the system player, so there is no YouTube chrome or ads.
///
/// Everything else on the protocol is an inert stub: a trailer is a single leaf
/// with nothing to browse, search, or report progress for.
public struct YouTubeTrailerProvider: MediaProvider {
    /// The trailer leaf being played (title/runtime used for the transport UI).
    private let trailerItem: MediaItem
    /// The YouTube video id to extract a stream for.
    private let videoID: String
    /// Extraction methods in priority order; defaults to YouTubeKit's platform
    /// default (local JavaScriptCore extraction on tvOS).
    private let methods: [YouTube.ExtractionMethod]

    public init(
        item: MediaItem,
        videoID: String,
        methods: [YouTube.ExtractionMethod] = .default
    ) {
        self.trailerItem = item
        self.videoID = videoID
        self.methods = methods
    }

    /// Placeholder — unused: nothing reads a trailer provider's kind, the player
    /// only calls ``playbackInfo(for:)``. Reuses an existing case to avoid
    /// widening `ProviderKind` for an internal, non-account provider.
    public var kind: ProviderKind { .jellyfin }

    /// Placeholder session — a trailer provider is not bound to a real account.
    public var session: UserSession {
        UserSession(
            server: MediaServer(
                id: "youtube-trailer",
                name: "YouTube",
                baseURL: URL(string: "https://www.youtube.com")!,
                provider: .jellyfin
            ),
            userID: "",
            userName: "",
            deviceID: "",
            accessToken: ""
        )
    }

    // MARK: Playback (the only real work)

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        let video = YouTube(videoID: videoID, methods: methods)

        let streams: [YouTubeKit.Stream]
        do {
            streams = try await video.streams
        } catch {
            throw AppError.unknown("trailer-extract")
        }

        // Prefer a progressive stream carrying both audio + video that the device
        // can decode natively (AVPlayer can't mux separate adaptive tracks from
        // bare URLs). Fall back to the best natively-playable stream otherwise.
        let playable = streams.filter { $0.isNativelyPlayable }
        guard let best = playable.filterVideoAndAudio().highestResolutionStream()
                ?? playable.highestResolutionStream()
        else {
            throw AppError.notFound
        }

        return PlaybackRequest(
            item: trailerItem,
            streamURL: best.url,
            startPosition: 0
        )
    }

    // MARK: Inert stubs (a trailer has nothing to browse / search / report)

    public func libraries() async throws -> [MediaLibrary] { [] }
    public func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    public func latest(limit: Int) async throws -> [MediaItem] { [] }
    public func item(id: String) async throws -> MediaItem { trailerItem }
    public func children(of itemID: String) async throws -> [MediaItem] { [] }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }

    public func search(query: String, limit: Int) async throws -> [MediaItem] { [] }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
