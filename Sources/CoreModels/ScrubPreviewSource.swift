import Foundation

/// Credential-free instructions for loading one scrub-preview resource.
public enum ScrubPreviewResource: Hashable, Sendable {
    case publicURL(SecretFreeURLSource)
    case authenticatedHTTP(AuthenticatedHTTPPlaybackLocator)

    public var immediateURL: URL? {
        guard case .publicURL(let source) = self else { return nil }
        return source.url
    }
}

/// Where the custom player sources its scrubbing-preview ("trickplay")
/// thumbnails from for one playable item.
///
/// Each server pre-generates scrub previews in a different shape, so this enum
/// lets `PlaybackRequest` stay provider-agnostic while the player picks the
/// matching loader:
///  * **Jellyfin** packs thumbnails into a few grid "tile" images described by a
///    `TrickplayManifest` (`.tiled`).
///  * **Plex / Emby** store them in a single Roku **BIF** index file that the client
///    downloads and slices frame-by-frame (`.plexBIF`).
///
/// An unusable/absent source simply means the player shows no scrub preview — it
/// never blocks playback.
public enum ScrubPreviewSource: Hashable, Sendable {
    /// Pre-tiled grid images (Jellyfin trickplay).
    case tiled(TrickplayManifest)
    /// A single **BIF** index file (Roku trickplay format) to download and
    /// parse lazily. The blob packs every preview frame plus a fixed-interval
    /// index; the player slices frames out of it while scrubbing.
    case plexBIF(resource: ScrubPreviewResource)

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

    /// The BIF index URL, when this source is BIF-based; `nil` otherwise.
    public var plexBIFResource: ScrubPreviewResource? {
        if case .plexBIF(let resource) = self { return resource }
        return nil
    }
}
