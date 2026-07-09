import Foundation

/// The media backends Plozz can talk to.
///
/// Plozz is dual-provider: **Jellyfin** and **Plex** are first-class, co-equal
/// backends. Everything above the provider layer talks to ``MediaProvider``, so
/// adding a new backend (e.g. Overseerr) only requires a new conformer and a
/// case here — no feature rewrites.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case jellyfin
    case plex
    /// A local network media share (SMB today). Deliberately **second-class**:
    /// there's no server doing library management, metadata, or watch-state, so
    /// Plozz scans the files itself and synthesises everything a first-class
    /// backend would hand us. See docs/media-share-proposal.md.
    case mediaShare

    public var displayName: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .mediaShare: return "Media Share"
        }
    }

    /// Whether `MediaProvider.playbackInfo` is idempotent — i.e. resolving a
    /// stream has **no server-side session side-effects**, so it is safe to call
    /// EARLY (an eager next-episode prefetch) without opening a duplicate or
    /// orphaned playback/transcode session.
    ///
    /// - **Plex / mediaShare → `true`.** Plex `playbackInfo` is a read-only
    ///   metadata GET with a deterministic client-minted session id; a media
    ///   share just builds a local `smb://` URL. Calling either ahead of time is
    ///   free and repeatable, so the next episode can be resolved the moment it's
    ///   known for a near-instant hand-off.
    /// - **Jellyfin → `false`.** Its `POST /Items/{id}/PlaybackInfo`
    ///   (`AutoOpenLiveStream: true`) mints a NEW server `PlaySessionId` and may
    ///   start a transcode job. Prefetching it eagerly would orphan a session, so
    ///   the next-episode prefetch is deferred to the hand-off window and the
    ///   resolved request is reused (or released on back-out) rather than
    ///   re-resolved.
    public var playbackInfoIsIdempotent: Bool {
        switch self {
        case .plex, .mediaShare: return true
        case .jellyfin: return false
        }
    }
}
