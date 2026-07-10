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

    /// Process-wide serial gate for YouTubeKit's local (JavaScriptCore) stream
    /// extraction. Each extraction spins up a JSContext that runs YouTube's large
    /// obfuscated player JS to decipher stream signatures; running several at once
    /// stacks multiple multi-hundred-MB JS heaps and pins JavaScriptCore's garbage
    /// collector at ~300% CPU — the navigation-churn freeze (memory ballooning to
    /// ~1.7 GB) and the jetsam crashes that follow it. Tap-through of several
    /// titles, each verifying multiple candidate trailer ids concurrently, is what
    /// stacks them. Capping to ONE in-flight extraction bounds the live JS heap to
    /// a single context, so the GC never thrashes. This costs nothing real:
    /// trailer extraction is off the first-paint path and most titles resolve one
    /// or two ids, so serializing keeps verification fast while making the memory
    /// footprint flat instead of explosive.
    static let extractionGate = ConcurrencyLimiter(limit: 1)

    /// Process-wide, time-bounded cache of in-flight and recently-resolved
    /// YouTube stream extractions, keyed by video id. Two callers race for the
    /// same id during trailer fast-start: the detail screen verifies which
    /// trailer id plays (warming this cache), then a Play tap resolves the *same*
    /// id again. Sharing the resolution makes that second resolve effectively
    /// instant. A short TTL bounds reuse because resolved stream URLs carry a
    /// time-limited signature — long enough to cover verify→play and brief
    /// revisits, short enough to never hand back a stale (expired) URL.
    actor StreamCache {
        static let shared = StreamCache()

        private struct Entry {
            let task: Task<[YouTubeKit.Stream], Error>
            let createdAt: Date
        }
        private var entries: [String: Entry] = [:]
        /// Reuse window. Trailer extraction itself takes a couple of seconds, so
        /// this leaves a comfortable post-resolution reuse margin while staying
        /// well inside YouTube's URL signature lifetime.
        private let ttl: TimeInterval = 180

        func streams(for id: String, methods: [YouTube.ExtractionMethod]) async throws -> [YouTubeKit.Stream] {
            if let entry = entries[id], Date().timeIntervalSince(entry.createdAt) < ttl {
                do {
                    return try await entry.task.value
                } catch {
                    // A cached failure is not sticky: drop it so a later attempt
                    // (or a recovered network) can re-resolve.
                    if entries[id]?.createdAt == entry.createdAt { entries[id] = nil }
                    throw error
                }
            }
            let task = Task { () throws -> [YouTubeKit.Stream] in
                try await YouTubeTrailerProvider.extractionGate.run {
                    try await YouTube(videoID: id, methods: methods).streams
                }
            }
            entries[id] = Entry(task: task, createdAt: Date())
            do {
                return try await task.value
            } catch {
                entries[id] = nil
                throw error
            }
        }
    }
    /// Optional source of replacement trailer video ids, tried in order when the
    /// primary video is unavailable. `nil` (the default) means no fallback.
    private let alternatives: AlternativeResolving?
    /// Whether this provider may resolve a higher-resolution **adaptive** stream
    /// (separate video + audio tracks the Plozzigen engine muxes). Set from the
    /// player composition: `true` only when a hybrid engine is actually wired in,
    /// so a build with native-AVPlayer-only playback never gets a video-only URL
    /// it can't add sound to.
    private let allowsSeparateAudio: Bool

    public init(
        item: MediaItem,
        videoID: String,
        methods: [YouTube.ExtractionMethod] = [.local, .remote],
        alternatives: AlternativeResolving? = nil,
        allowsSeparateAudio: Bool = true
    ) {
        self.trailerItem = item
        self.videoID = videoID
        self.methods = methods
        self.alternatives = alternatives
        self.allowsSeparateAudio = allowsSeparateAudio
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
        try await resolvePlayback(allowAdaptive: allowsSeparateAudio)
    }

    /// The engine-failure fallback asks for a "safe" stream (`forceTranscode`)
    /// when the high-resolution adaptive (hybrid) path fails mid-playback: a
    /// self-contained muxed/HLS URL AVPlayer plays directly, so a failed hybrid
    /// trailer recovers *with sound* instead of a silent video-only swap.
    public func playbackInfo(for itemID: String, forceTranscode: Bool) async throws -> PlaybackRequest {
        try await resolvePlayback(allowAdaptive: forceTranscode ? false : allowsSeparateAudio)
    }

    /// Resolves a playable request for the primary trailer video, falling back to
    /// replacement videos when the primary is unavailable. `allowAdaptive` gates
    /// the higher-resolution separate-track path (off for the safe/recovery pass).
    private func resolvePlayback(allowAdaptive: Bool) async throws -> PlaybackRequest {
        // Try the primary (server- or search-resolved) video first.
        let primaryError: Error
        do {
            let stream = try await resolveTrailerStream(forVideoID: videoID, allowAdaptive: allowAdaptive)
            return makeRequest(from: stream)
        } catch {
            primaryError = error
        }

        // The primary video couldn't be played — most often a stale server
        // `RemoteTrailers` URL pointing at a video that has since been made
        // private/removed. Best-effort: search for a replacement trailer for the
        // same title and play the first one that resolves.
        for altID in await alternatives?() ?? [] where altID != videoID {
            if let stream = try? await resolveTrailerStream(forVideoID: altID, allowAdaptive: allowAdaptive) {
                return makeRequest(from: stream)
            }
        }

        // Nothing playable. Surface an honest error rather than a misleading
        // "something went wrong, try again": an unavailable video won't recover on
        // retry.
        if primaryError is TrailerVideoUnavailable {
            throw AppError.notFound
        }
        if let appError = primaryError as? AppError {
            throw appError
        }
        throw AppError.unknown("trailer-extract")
    }

    /// Builds a `PlaybackRequest` from a resolved stream, carrying the companion
    /// audio URL for an adaptive (separate-track) source so the hybrid engine can
    /// mux it.
    private func makeRequest(from stream: TrailerStream) -> PlaybackRequest {
        PlaybackRequest(
            item: trailerItem,
            streamURL: stream.videoURL,
            externalAudioURL: stream.audioURL,
            startPosition: 0
        )
    }

    /// Returns the first candidate video id that resolves to a playable **public**
    /// stream, skipping any YouTube reports as private/removed/region-blocked.
    /// `nil` when none are playable.
    ///
    /// Candidates are verified **concurrently** (extraction + a byte-reach check
    /// each), but the result preserves priority order: the lowest-index candidate
    /// that actually streams wins. Verifying in parallel keeps the authoritative
    /// pass fast even with several fallback ids, instead of paying each round-trip
    /// serially.
    ///
    /// Used to decide whether to surface a Trailer button (and which video to
    /// play), so a stale server `RemoteTrailers` link that points at a now-private
    /// video never produces an unplayable button. All interaction goes through
    /// YouTubeKit — this never bypasses a private gate, it only filters dead
    /// candidates out.
    public static func firstPlayableVideoID(
        in candidates: [String],
        methods: [YouTube.ExtractionMethod] = [.local, .remote]
    ) async -> String? {
        let indexed = candidates.enumerated().filter { !$0.element.isEmpty }
        guard !indexed.isEmpty else { return nil }

        let bestIndex = await withTaskGroup(of: (Int, Bool).self) { group -> Int? in
            for (index, id) in indexed {
                group.addTask { (index, await isPlayable(videoID: id, methods: methods)) }
            }
            var best: Int?
            for await (index, playable) in group where playable {
                best = min(best ?? index, index)
            }
            return best
        }

        guard let bestIndex else { return nil }
        return indexed.first(where: { $0.offset == bestIndex })?.element
    }

    /// Whether each candidate trailer **exists and is embeddable**, decided by a
    /// single cheap keyless HTTP GET against YouTube's public oEmbed endpoint —
    /// crucially with **no JavaScriptCore**. This is the browse-time signal for
    /// whether to surface a Trailer button; full stream extraction (which spins up
    /// a persistent ~512MB JSContext VM reservation, the biggest memory cost of a
    /// detail page) is deferred to *tap*, when the video is actually played and the
    /// player's own primary→alternatives fallback also runs.
    ///
    /// oEmbed returns **200** for a public, embeddable video; **401/403** for a
    /// private or embedding-disabled one; **404** for a removed/nonexistent one.
    /// Only a 200 surfaces a button, so a dead or gated link never yields a fake
    /// "there's a trailer" button — the exact accuracy guarantee the JavaScriptCore
    /// verifier gave, at a tiny fraction of the cost. Returns the FIRST candidate
    /// (in priority order) that passes, mirroring ``firstPlayableVideoID(in:)``.
    public static func firstEmbeddableVideoID(in candidates: [String]) async -> String? {
        let indexed = candidates.enumerated().filter { !$0.element.isEmpty }
        guard !indexed.isEmpty else { return nil }

        let bestIndex = await withTaskGroup(of: (Int, Bool).self) { group -> Int? in
            for (index, id) in indexed {
                group.addTask { (index, await isEmbeddable(videoID: id)) }
            }
            var best: Int?
            for await (index, ok) in group where ok {
                best = min(best ?? index, index)
            }
            return best
        }

        guard let bestIndex else { return nil }
        return indexed.first(where: { $0.offset == bestIndex })?.element
    }

    /// One keyless oEmbed existence/embeddability probe (HTTP GET, no
    /// JavaScriptCore). `true` only on HTTP 200 (public + embeddable). Best-effort:
    /// any network error or non-200 counts as "don't surface a button", so we never
    /// show a trailer button we can't stand behind.
    static func isEmbeddable(videoID id: String) async -> Bool {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }
    /// Verification uses the reliable muxed/HLS path (`allowAdaptive: false`): if
    /// that plays, the higher-res adaptive upgrade chosen at play time is safe (it
    /// shares the same video) and self-heals to this stream if it ever fails.
    private static func isPlayable(videoID id: String, methods: [YouTube.ExtractionMethod]) async -> Bool {
        guard let stream = try? await resolveTrailerStream(forVideoID: id, methods: methods, allowAdaptive: false) else {
            return false
        }
        // Extraction succeeding isn't enough — the resolved URL must actually
        // serve media bytes. A YouTube HLS manifest can load (HTTP 200) while its
        // segments 403, so confirm the chosen stream is reachable.
        let reachable = await isStreamReachable(stream.videoURL)
        return reachable
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

    /// Resolves the best playable stream for one YouTube `id`.
    ///
    /// Selection (see ``TrailerStreamSelector``) prefers, in order: a
    /// higher-resolution **adaptive** video+audio pair the hybrid engine muxes
    /// (when `allowAdaptive`), then a **progressive muxed** MP4 AVPlayer plays
    /// directly, then any single natively-playable stream, then YouTube's HLS
    /// manifest. Progressive/adaptive googlevideo URLs serve their bytes directly;
    /// HLS is last because its segments are currently PO-token gated (HTTP 403).
    /// Throws ``TrailerVideoUnavailable`` when YouTube reports the video can't be
    /// played (private/removed/age-restricted/region-blocked) so callers can try a
    /// replacement.
    private func resolveTrailerStream(forVideoID id: String, allowAdaptive: Bool) async throws -> TrailerStream {
        try await Self.resolveTrailerStream(forVideoID: id, methods: methods, allowAdaptive: allowAdaptive)
    }

    /// Stateless stream resolution shared by instance playback and the static
    /// ``firstPlayableVideoID(in:methods:)`` verifier.
    private static func resolveTrailerStream(
        forVideoID id: String,
        methods: [YouTube.ExtractionMethod],
        allowAdaptive: Bool
    ) async throws -> TrailerStream {
        // Resolve concrete streams first so YouTube's unavailability signal
        // (private/removed/region-blocked) surfaces as TrailerVideoUnavailable.
        let streams: [YouTubeKit.Stream]
        do {
            streams = try await StreamCache.shared.streams(for: id, methods: methods)
        } catch let ytError as YouTubeKitError where Self.isUnavailable(ytError) {
            throw TrailerVideoUnavailable()
        } catch {
            streams = []
        }

        // 1-3) Adaptive hi-res pair / progressive muxed / any native single.
        let candidates = streams.map(TrailerStreamCandidate.init)
        if let chosen = TrailerStreamSelector.selectTrailerStream(from: candidates, allowAdaptive: allowAdaptive) {
            return chosen
        }

        // 4) HLS manifest — fallback for livestreams and the rare VOD without a
        //    usable progressive/adaptive stream. May fail on PO-token-gated
        //    segments, so it's the last resort.
        let livestreamURL = await extractionGate.run {
            (try? await YouTube(videoID: id, methods: methods).livestreams)?.first?.url
        }
        if let hls = livestreamURL {
            return TrailerStream(videoURL: hls)
        }

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
