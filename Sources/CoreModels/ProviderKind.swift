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

    public var displayName: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        }
    }
}
