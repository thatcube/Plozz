#if canImport(UIKit)
import CoreGraphics
import Foundation

/// A source of scrubbing-preview thumbnails the custom player can query by
/// playback position, independent of how the server delivers them (Jellyfin
/// trickplay tiles vs. a Plex BIF blob).
///
/// Two access paths mirror the player's needs: a synchronous fast path that
/// returns a frame only if it's already in memory (so dragging stays fluid), and
/// an async path that fetches/decodes on demand.
@MainActor
protocol ScrubThumbnailProviding: AnyObject {
    /// The thumbnail for a playback position, fetching/decoding if needed.
    func thumbnail(forSeconds seconds: TimeInterval) async -> CGImage?

    /// The thumbnail for a playback position **only if** it's already available
    /// in memory; `nil` otherwise (the caller should fall back to the async
    /// path). Lets the overlay swap frames instantly while scrubbing.
    func cachedThumbnail(forSeconds seconds: TimeInterval) -> CGImage?
}
#endif
