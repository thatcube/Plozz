import Foundation

// MARK: - Provider capabilities (additive, non-breaking)
//
// A lightweight, declarative description of what a provider/account can do, used
// to drive conditional UI (e.g. show the Music tab only when some account
// advertises `.music`). This is an *additive* helper — it does not change the
// `MediaProvider` contract; a provider can advertise capabilities by conforming
// to `CapabilityReporting` (optional, with a `.video`-only default), and music
// support is independently detectable via `as? MusicProvider`.
//
// See `docs/music-library-proposal.md`.

/// The broad content/feature capabilities a provider may expose.
public struct ProviderCapability: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Browse and play video libraries (movies, TV). Every provider has this.
    public static let video = ProviderCapability(rawValue: 1 << 0)
    /// Browse and play a music library (artists/albums/tracks/playlists).
    public static let music = ProviderCapability(rawValue: 1 << 1)
    /// Search remote subtitle services and download subtitles.
    public static let remoteSubtitles = ProviderCapability(rawValue: 1 << 2)

    /// The baseline every provider supports today.
    public static let videoOnly: ProviderCapability = [.video]
}

/// Optional protocol a provider may adopt to advertise its capabilities. Default
/// is video-only, so existing providers need no changes; a music-capable
/// provider can override to add `.music`.
public protocol CapabilityReporting {
    var capabilities: ProviderCapability { get }
}

public extension CapabilityReporting {
    var capabilities: ProviderCapability { .videoOnly }
}

public extension Sequence {
    /// Whether any element in this sequence advertises `capability`, treating a
    /// `MusicProvider` conformer as implicitly `.music`-capable even if it does
    /// not separately adopt `CapabilityReporting`.
    ///
    /// Drives conditional UI such as "show the Music tab only when at least one
    /// account exposes music".
    func advertisesCapability(_ capability: ProviderCapability) -> Bool {
        contains { element in
            if capability.contains(.music), element is MusicProvider {
                return true
            }
            if let reporting = element as? CapabilityReporting {
                return reporting.capabilities.contains(capability)
            }
            return false
        }
    }
}
