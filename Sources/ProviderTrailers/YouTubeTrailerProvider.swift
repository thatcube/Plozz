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
    /// Resolves *alternative* YouTube video ids to try when the primary trailer
    /// video can't be played (e.g. a stale server `RemoteTrailers` URL that points
    /// at a now-private/removed video). Best-effort and injected so this low-level
    /// provider stays decoupled from whatever produces the candidates (typically a
    /// keyless YouTube search by title). Returning an empty list disables recovery.
    public typealias AlternativeResolving = @Sendable () async -> [String]

    /// The trailer leaf being played (title/runtime used for the transport UI).
    private let trailerItem: MediaItem
    /// The YouTube video id to extract a stream for.
    private let videoID: String
    /// Extraction methods in priority order. Defaults to local JavaScriptCore
    /// extraction first, then YouTubeKit's hosted remote fallback — so trailers
    /// keep resolving even if YouTube changes its internals before the app can be
    /// updated. The remote service makes its requests *through* this device, so
    /// resolved stream URLs stay valid for playback here.
    private let methods: [YouTube.ExtractionMethod]
    /// Optional source of replacement trailer video ids, tried in order when the
    /// primary video is unavailable. `nil` (the default) means no fallback.
    private let alternatives: AlternativeResolving?

    public init(
        item: MediaItem,
        videoID: String,
        methods: [YouTube.ExtractionMethod] = [.local, .remote],
        alternatives: AlternativeResolving? = nil
    ) {
        self.trailerItem = item
        self.videoID = videoID
        self.methods = methods
        self.alternatives = alternatives
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
        // Try the primary (server- or search-resolved) video first.
        let primaryError: Error
        do {
            return PlaybackRequest(
                item: trailerItem,
                streamURL: try await resolveStreamURL(forVideoID: videoID),
                startPosition: 0
            )
        } catch {
            primaryError = error
        }

        // The primary video couldn't be played — most often a stale server
        // `RemoteTrailers` URL pointing at a video that has since been made
        // private/removed. Best-effort: search for a replacement trailer for the
        // same title and play the first one that resolves.
        for altID in await alternatives?() ?? [] where altID != videoID {
            if let url = try? await resolveStreamURL(forVideoID: altID) {
                return PlaybackRequest(item: trailerItem, streamURL: url, startPosition: 0)
            }
        }

        // Nothing playable. Surface an honest error rather than a misleading
        // "something went wrong, try again": an unavailable video won't recover on
        // retry.
        if primaryError is TrailerVideoUnavailable { throw AppError.notFound }
        if let appError = primaryError as? AppError { throw appError }
        throw AppError.unknown("trailer-extract")
    }

    /// Resolves a natively-playable stream URL for one YouTube `id`.
    ///
    /// Prefers YouTube's HLS manifest — an adaptive, audio+video-muxed,
    /// full-resolution playlist that `AVPlayer` plays natively on tvOS and that
    /// stays available even when progressive streams don't. Falls back to a
    /// progressive (muxed) stream, then any natively-decodable stream. Throws
    /// ``TrailerVideoUnavailable`` when YouTube reports the video can't be played
    /// (private/removed/age-restricted/region-blocked) so callers can try a
    /// replacement.
    private func resolveStreamURL(forVideoID id: String) async throws -> URL {
        let video = YouTube(videoID: id, methods: methods)

        // 1) HLS manifest (best quality + most robust on AVPlayer). Resolved on
        //    this device, so its IP-scoped URL stays valid for playback here.
        //    Only succeeds for playable videos; a no-op for those without HLS.
        if let hls = (try? await video.livestreams)?.first?.url {
            return hls
        }

        // 2) Concrete progressive/adaptive streams.
        let streams: [YouTubeKit.Stream]
        do {
            streams = try await video.streams
        } catch let ytError as YouTubeKitError where Self.isUnavailable(ytError) {
            throw TrailerVideoUnavailable()
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
        return best.url
    }

    /// Whether a YouTubeKit failure means the video itself can't be played here
    /// (as opposed to a transient/extraction glitch) — the cue to try a
    /// replacement trailer instead of retrying the same dead video.
    private static func isUnavailable(_ error: YouTubeKitError) -> Bool {
        switch error {
        case .videoPrivate, .videoUnavailable, .videoAgeRestricted,
             .membersOnly, .videoRegionBlocked, .recordingUnavailable, .liveStreamError:
            return true
        default:
            return false
        }
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

/// Internal sentinel: the requested YouTube video can't be played (private,
/// removed, age-restricted, region-blocked, …). Signals ``YouTubeTrailerProvider``
/// to try a replacement trailer before giving up.
private struct TrailerVideoUnavailable: Error {}
