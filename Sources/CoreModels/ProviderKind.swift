import Foundation

/// The media backends Plizz can talk to.
///
/// Phase 1 ships `.jellyfin` only. `.plex` is reserved for Phase 2 and exists
/// here so that persisted data and the `MediaProvider` abstraction are already
/// provider-aware — no migration needed when Plex lands.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case jellyfin
    case plex

    public var displayName: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        }
    }
}
