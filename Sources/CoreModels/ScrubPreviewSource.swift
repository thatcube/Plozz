import Foundation

/// Where the custom player sources its scrubbing-preview ("trickplay")
/// thumbnails from for one playable item.
///
/// Each server pre-generates scrub previews in a different shape, so this enum
/// lets `PlaybackRequest` stay provider-agnostic while the player picks the
/// matching loader:
///  * **Jellyfin** packs thumbnails into a few grid "tile" images described by a
///    `TrickplayManifest` (`.tiled`).
///  * **Plex** stores them in a single Roku **BIF** index file that the client
///    downloads and slices frame-by-frame (`.plexBIF`).
///
/// An unusable/absent source simply means the player shows no scrub preview — it
/// never blocks playback.
public enum ScrubPreviewSource: Hashable, Sendable {
    /// Pre-tiled grid images (Jellyfin trickplay).
    case tiled(TrickplayManifest)
    /// A single Plex **BIF** index file (Roku trickplay format) to download and
    /// parse lazily. The blob packs every preview frame plus a fixed-interval
    /// index; the player slices frames out of it while scrubbing.
    case plexBIF(url: URL)

    /// Whether this source can actually yield previews.
    public var isUsable: Bool {
        switch self {
        case .tiled(let manifest): return manifest.isUsable
        case .plexBIF: return true
        }
    }

    /// The tiled manifest, when this source is tile-based; `nil` otherwise.
    public var tiledManifest: TrickplayManifest? {
        if case .tiled(let manifest) = self { return manifest }
        return nil
    }

    /// The Plex BIF index URL, when this source is BIF-based; `nil` otherwise.
    public var plexBIFURL: URL? {
        if case .plexBIF(let url) = self { return url }
        return nil
    }
}
