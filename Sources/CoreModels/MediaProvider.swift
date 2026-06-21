import Foundation

/// The provider abstraction that lets Plizz support multiple backends.
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
    func children(of itemID: String) async throws -> [MediaItem]

    // MARK: Playback

    /// Resolve a playable stream (+ tracks + resume point) for an item.
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest

    /// Report progress so the server keeps resume points in sync.
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws

    // MARK: Images

    /// Absolute URL for an item's artwork, or `nil` if unavailable.
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL?
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
