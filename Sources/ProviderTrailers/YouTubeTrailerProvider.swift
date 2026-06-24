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
        plozzTrace("YTTrailer.playbackInfo: primary videoID=\(videoID) methods=\(methods)")
        // Try the primary (server- or search-resolved) video first.
        let primaryError: Error
        do {
            let url = try await resolveStreamURL(forVideoID: videoID)
            plozzTrace("YTTrailer.playbackInfo: primary RESOLVED url=\(url.absoluteString.prefix(120))")
            return PlaybackRequest(
                item: trailerItem,
                streamURL: url,
                startPosition: 0
            )
        } catch {
            primaryError = error
            plozzTrace("YTTrailer.playbackInfo: primary FAILED error=\(String(reflecting: error))")
        }

        // The primary video couldn't be played — most often a stale server
        // `RemoteTrailers` URL pointing at a video that has since been made
        // private/removed. Best-effort: search for a replacement trailer for the
        // same title and play the first one that resolves.
        for altID in await alternatives?() ?? [] where altID != videoID {
            plozzTrace("YTTrailer.playbackInfo: trying alternative videoID=\(altID)")
            if let url = try? await resolveStreamURL(forVideoID: altID) {
                plozzTrace("YTTrailer.playbackInfo: alternative RESOLVED \(altID) url=\(url.absoluteString.prefix(120))")
                return PlaybackRequest(item: trailerItem, streamURL: url, startPosition: 0)
            }
        }

        // Nothing playable. Surface an honest error rather than a misleading
        // "something went wrong, try again": an unavailable video won't recover on
        // retry.
        if primaryError is TrailerVideoUnavailable {
            plozzTrace("YTTrailer.playbackInfo: no playable trailer -> throwing AppError.notFound (primary unavailable)")
            throw AppError.notFound
        }
        if let appError = primaryError as? AppError {
            plozzTrace("YTTrailer.playbackInfo: no playable trailer -> rethrowing primary AppError=\(appError)")
            throw appError
        }
        plozzTrace("YTTrailer.playbackInfo: no playable trailer -> throwing AppError.unknown(trailer-extract)")
        throw AppError.unknown("trailer-extract")
    }

    /// Returns the first candidate video id that resolves to a playable **public**
    /// stream, trying each in order and skipping any YouTube reports as
    /// private/removed/region-blocked. `nil` when none are playable.
    ///
    /// Used to decide whether to surface a Trailer button (and which video to
    /// play) *before* showing it, so a stale server `RemoteTrailers` link that
    /// points at a now-private video never produces an unplayable button. All
    /// interaction goes through YouTubeKit — this never bypasses a private gate,
    /// it only filters dead candidates out.
    public static func firstPlayableVideoID(
        in candidates: [String],
        methods: [YouTube.ExtractionMethod] = [.local, .remote]
    ) async -> String? {
        for id in candidates where !id.isEmpty {
            guard let url = try? await resolveStreamURL(forVideoID: id, methods: methods) else {
                plozzTrace("YTTrailer.firstPlayableVideoID: \(id) did not resolve, trying next")
                continue
            }
            // Extraction succeeding isn't enough — the resolved URL must actually
            // serve media bytes. A YouTube HLS manifest can load (HTTP 200) while
            // its segments 403, so confirm the chosen stream is reachable before
            // surfacing it.
            if await isStreamReachable(url) {
                plozzTrace("YTTrailer.firstPlayableVideoID: \(id) is playable")
                return id
            }
            plozzTrace("YTTrailer.firstPlayableVideoID: \(id) resolved but not reachable, trying next")
        }
        return nil
    }

    /// Whether `url`'s media bytes are actually fetchable — a tiny ranged GET that
    /// follows redirects and accepts a 2xx (incl. 206 Partial Content). Used to
    /// confirm a trailer really streams before showing its button, so a stale or
    /// gated link never yields a dead "Can't play this" button. Best-effort: any
    /// network error counts as not reachable.
    private static func isStreamReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200...299).contains(http.statusCode)
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
    /// Resolves a natively-playable stream URL for one YouTube `id`.
    ///
    /// Prefers a **progressive muxed** (audio+video) MP4 stream: these serve their
    /// media bytes directly and play natively on `AVPlayer`. YouTube's HLS variant
    /// manifest is only used as a fallback (live content, or the rare video with no
    /// muxed progressive) because its media segments are currently PO-token gated
    /// and return HTTP 403 — the manifest/playlist load (200) but every segment
    /// fails, which surfaces as a mid-playback `invalidResponse`. Throws
    /// ``TrailerVideoUnavailable`` when YouTube reports the video can't be played
    /// (private/removed/age-restricted/region-blocked) so callers can try a
    /// replacement.
    private func resolveStreamURL(forVideoID id: String) async throws -> URL {
        try await Self.resolveStreamURL(forVideoID: id, methods: methods)
    }

    /// Stateless stream resolution shared by instance playback and the static
    /// ``firstPlayableVideoID(in:methods:)`` verifier.
    private static func resolveStreamURL(forVideoID id: String, methods: [YouTube.ExtractionMethod]) async throws -> URL {
        let video = YouTube(videoID: id, methods: methods)

        // Resolve concrete streams first so YouTube's unavailability signal
        // (private/removed/region-blocked) surfaces as TrailerVideoUnavailable.
        let streams: [YouTubeKit.Stream]
        do {
            streams = try await video.streams
            plozzTrace("YTTrailer.resolveStreamURL[\(id)]: streams count=\(streams.count)")
        } catch let ytError as YouTubeKitError where Self.isUnavailable(ytError) {
            plozzTrace("YTTrailer.resolveStreamURL[\(id)]: UNAVAILABLE ytError=\(ytError)")
            throw TrailerVideoUnavailable()
        } catch {
            plozzTrace("YTTrailer.resolveStreamURL[\(id)]: streams threw non-availability error=\(String(reflecting: error)); trying HLS")
            streams = []
        }

        let playable = streams.filter { $0.isNativelyPlayable }

        // 1) Progressive muxed (audio+video) — the reliable path. AVPlayer can't
        //    mux separate adaptive tracks from bare URLs, and these progressive
        //    URLs (unlike HLS segments) serve bytes directly.
        if let muxed = playable.filterVideoAndAudio().highestResolutionStream() {
            plozzTrace("YTTrailer.resolveStreamURL[\(id)]: using progressive muxed stream")
            return muxed.url
        }

        // 2) HLS manifest — fallback for livestreams and the rare VOD without a
        //    muxed progressive. May fail on PO-token-gated segments.
        if let hls = (try? await video.livestreams)?.first?.url {
            plozzTrace("YTTrailer.resolveStreamURL[\(id)]: no muxed progressive; using HLS manifest")
            return hls
        }

        // 3) Last resort: any natively-playable stream (e.g. video-only).
        if let best = playable.highestResolutionStream() {
            plozzTrace("YTTrailer.resolveStreamURL[\(id)]: using best natively-playable stream")
            return best.url
        }

        plozzTrace("YTTrailer.resolveStreamURL[\(id)]: no playable stream -> notFound")
        throw AppError.notFound
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
