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

    /// Trailers / preview clips for an item (movie or series).
    ///
    /// Returned items are ordinary playable `MediaItem`s whose `id` resolves to a
    /// stream through this same provider's `playbackInfo(for:)`, so callers can
    /// hand a trailer straight to the player like any other leaf. Empty when the
    /// backend has no (playable) trailer for the item.
    func trailers(for itemID: String) async throws -> [MediaItem]

    /// Children of a container (season → episodes, series → seasons, …).
    ///
    /// Intended for small containers whose contents fit comfortably in one
    /// request. For potentially large containers (top-level libraries with
    /// hundreds of items) use `items(in:page:)` instead so the UI can page.
    func children(of itemID: String) async throws -> [MediaItem]

    /// A single page of a container's children, for scalable browsing of large
    /// libraries. Implementations request only `page.limit` items starting at
    /// `page.startIndex`, ordered by `page.sort`, and report the container's
    /// `totalCount` so callers can lazily fetch further pages on demand.
    ///
    /// `kind` is the container's kind (e.g. `.movie`/`.series` for a library
    /// view) so the provider can pick its most efficient, indexed query for that
    /// content type rather than an unbounded folder enumeration.
    ///
    /// All pages of a single browse session must be requested with the *same*
    /// `page.sort` so the sparse, index-addressed grid stays consistent; changing
    /// the sort means restarting paging from `startIndex` 0.
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage

    // MARK: Search

    /// Search the user's libraries for items matching a free-text query.
    ///
    /// Implementations search across the playable content types (movies, series,
    /// episodes) and return at most `limit` items. Callers debounce input and
    /// guard against stale responses, so this need only perform a single query.
    func search(query: String, limit: Int) async throws -> [MediaItem]

    // MARK: Playback

    /// Resolve a playable stream (+ tracks + resume point) for an item.
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest

    /// Resolve a playable stream, optionally forcing the server to transcode.
    ///
    /// When `forceTranscode` is `true`, the provider bypasses direct play/stream
    /// and asks the server for a transcoded stream. This is the automatic
    /// fallback the player uses when a direct-play stream fails to load in
    /// AVPlayer. Providers that can't force a transcode inherit a default that
    /// ignores the flag (so this stays additive — `false` == current behaviour).
    func playbackInfo(for itemID: String, forceTranscode: Bool) async throws -> PlaybackRequest

    /// Report progress so the server keeps resume points in sync.
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws

    // MARK: Subtitles

    /// Search remote subtitle services for subtitles matching `language`
    /// (an ISO code). Returns candidates that can be downloaded onto the server.
    func remoteSubtitleSearch(itemID: String, language: String) async throws -> [RemoteSubtitle]

    /// Ask the server to download a previously-searched remote subtitle and
    /// attach it to the item, so every client sees it.
    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws

    // MARK: Images

    /// Absolute URL for an item's artwork, or `nil` if unavailable.
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL?
}

// MARK: - Optional subtitle capability defaults
//
// Providers that don't support remote subtitle search/download (or test
// doubles) inherit safe no-ops, so adding the capability never forces every
// conformer to implement it.
public extension MediaProvider {
    func remoteSubtitleSearch(itemID: String, language: String) async throws -> [RemoteSubtitle] { [] }
    func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {}

    /// Default: no trailers. Providers that can surface them (Jellyfin local
    /// trailers, Plex extras) override this; test doubles and other conformers
    /// inherit the safe empty result, so adding the capability stays additive.
    func trailers(for itemID: String) async throws -> [MediaItem] { [] }

    /// Default: ignore `forceTranscode` and resolve normally. Providers that can
    /// force a server-side transcode (Jellyfin, Plex) override this; test doubles
    /// and other conformers inherit the safe pass-through.
    func playbackInfo(for itemID: String, forceTranscode: Bool) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID)
    }
}

/// A request for one page of a container's children.
public struct PageRequest: Equatable, Sendable {
    /// Zero-based index of the first item to fetch.
    public var startIndex: Int
    /// Maximum number of items to fetch in this page.
    public var limit: Int
    /// How the container's children should be ordered. All pages of a browse
    /// session share one descriptor; changing it restarts paging from index 0.
    public var sort: SortDescriptor

    public init(
        startIndex: Int = 0,
        limit: Int = PageRequest.defaultLimit,
        sort: SortDescriptor = .default
    ) {
        self.startIndex = startIndex
        self.limit = limit
        self.sort = sort
    }

    /// Default page size tuned for a tvOS 10-foot grid: large enough to fill the
    /// screen and minimise round trips, small enough to load quickly.
    public static let defaultLimit = 60

    /// The request for the page that follows this one, preserving the sort order.
    public func next() -> PageRequest {
        PageRequest(startIndex: startIndex + limit, limit: limit, sort: sort)
    }
}

/// The attribute a library grid is ordered by. Provider-agnostic; each provider
/// maps these onto its own native sort keys.
public enum SortField: String, CaseIterable, Codable, Sendable {
    /// Alphabetical, by the item's sort name/title.
    case name
    /// When the item was added to the library.
    case dateAdded
    /// The item's original release/premiere date.
    case releaseDate
    /// Audience/community score.
    case communityRating
    /// Total runtime/duration.
    case runtime
    /// Server-shuffled random order.
    case random

    /// A short, human-readable label for a sort menu.
    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .releaseDate: return "Release Date"
        case .communityRating: return "Rating"
        case .runtime: return "Runtime"
        case .random: return "Random"
        }
    }
}

/// The direction a `SortField` is ordered in.
public enum SortDirection: String, CaseIterable, Codable, Sendable {
    case ascending
    case descending

    /// A short, human-readable label for a sort menu.
    public var displayName: String {
        switch self {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }
}

/// A library sort order: which `SortField` and in which `SortDirection`.
public struct SortDescriptor: Equatable, Codable, Sendable {
    public var field: SortField
    public var direction: SortDirection

    public init(field: SortField, direction: SortDirection) {
        self.field = field
        self.direction = direction
    }

    /// The default order for a freshly opened library: name, ascending.
    public static let `default` = SortDescriptor(field: .name, direction: .ascending)
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
