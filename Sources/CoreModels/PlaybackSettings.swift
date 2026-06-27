import Foundation

/// Per-profile playback preferences (pure data model, mirrors `SpoilerSettings`
/// / `CaptionSettings`).
///
/// Today this is the **Skip intros** master switch: when on, the player offers a
/// "Skip Intro" / "Skip Credits" button as it reaches a server-detected marker
/// segment (see `MediaSegment`). Modelled as data so the default can move with
/// real feedback and finer-grained toggles can be added later without a rewrite.
public struct PlaybackSettings: Codable, Equatable, Sendable {
    /// When true, the player surfaces a focusable skip button while playback is
    /// inside an intro or credits segment. Off by default — opt-in, and a no-op
    /// on servers/items that expose no markers. Covers both intros and credits.
    public var skipIntros: Bool

    public init(skipIntros: Bool = false) {
        self.skipIntros = skipIntros
    }

    public static let `default` = PlaybackSettings()
}

// MARK: - Codable (tolerant of older / future persisted payloads)

public extension PlaybackSettings {
    private enum CodingKeys: String, CodingKey {
        case skipIntros
    }

    /// Decodes leniently so a payload written before a field existed still loads
    /// instead of resetting the whole struct to its defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PlaybackSettings.default
        self.skipIntros = try container.decodeIfPresent(Bool.self, forKey: .skipIntros) ?? defaults.skipIntros
    }
}
