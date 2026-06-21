import Foundation

/// The provider abstraction that lets Plozz support multiple backends.
///
/// Phase 1 ships a single conformer (`ProviderJellyfin.JellyfinProvider`).
/// Phase 2 adds a Plex conformer **without** changing any feature module:
/// features depend only on this protocol and the `CoreModels` value types.
///
/// All methods are `async` and throw `AppError`. Implementations must:
///  * never log secrets/tokens;
///  * map transport errors onto `AppError`;
///  * be safe to call from the main actor (network work hops off internally).
public protocol MediaProvider: Sendable {
    var kind: ProviderKind { get }

    /// The authenticated session this provider is bound to.
    var session: UserSession { get }

    // MARK: Library browsing

    /// Top-level libraries/views available to the user.
    func libraries() async throws -> [MediaLibrary]

    /// "Continue Watching" — partially played, resumable items.
    func continueWatching(limit: Int) async throws -> [MediaItem]

    /// Recently added items across the user's libraries.
    func latest(limit: Int) async throws -> [MediaItem]

    /// Full detail for a single item.
    func item(id: String) async throws -> MediaItem

    /// Children of a container (season → episodes, series → seasons, …).
    ///
    /// Intended for small containers whose contents fit comfortably in one
    /// request. For potentially large containers (top-level libraries with
    /// hundreds of items) use `items(in:page:)` instead so the UI can page.
    func children(of itemID: String) async throws -> [MediaItem]

    /// A single page of a container's children, for scalable browsing of large
    /// libraries. Implementations request only `page.limit` items starting at
    /// `page.startIndex` and report the container's `totalCount` so callers can
    /// lazily fetch further pages on demand.
    ///
    /// `kind` is the container's kind (e.g. `.movie`/`.series` for a library
    /// view) so the provider can pick its most efficient, indexed query for that
    /// content type rather than an unbounded folder enumeration.
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage

    // MARK: Playback

    /// Resolve a playable stream (+ tracks + resume point) for an item.
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest

    /// Report progress so the server keeps resume points in sync.
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws

    // MARK: Images

    /// Absolute URL for an item's artwork, or `nil` if unavailable.
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL?
}

/// A request for one page of a container's children.
public struct PageRequest: Equatable, Sendable {
    /// Zero-based index of the first item to fetch.
    public var startIndex: Int
    /// Maximum number of items to fetch in this page.
    public var limit: Int

    public init(startIndex: Int = 0, limit: Int = PageRequest.defaultLimit) {
        self.startIndex = startIndex
        self.limit = limit
    }

    /// Default page size tuned for a tvOS 10-foot grid: large enough to fill the
    /// screen and minimise round trips, small enough to load quickly.
    public static let defaultLimit = 60

    /// The request for the page that follows this one.
    public func next() -> PageRequest {
        PageRequest(startIndex: startIndex + limit, limit: limit)
    }
}

/// One page of a container's children plus the total available, so callers can
/// page lazily without over-fetching large libraries.
public struct MediaPage: Equatable, Sendable {
    public var items: [MediaItem]
    /// Zero-based index of `items.first` within the full container.
    public var startIndex: Int
    /// Total number of items in the container across all pages.
    public var totalCount: Int

    public init(items: [MediaItem], startIndex: Int, totalCount: Int) {
        self.items = items
        self.startIndex = startIndex
        self.totalCount = totalCount
    }

    /// Index one past the last item in this page.
    public var endIndex: Int { startIndex + items.count }

    /// Whether more items remain beyond this page.
    public var hasMore: Bool { endIndex < totalCount }
}

/// Lifecycle events reported during playback.
public enum PlaybackEvent: String, Sendable {
    case start
    case progress
    case pause
    case unpause
    case stop
}

/// Artwork variants a provider can serve.
public enum ImageKind: String, Sendable {
    case primary
    case backdrop
    case thumb
    case logo
}
