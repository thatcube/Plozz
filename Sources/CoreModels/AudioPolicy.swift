import Foundation

// MARK: - Shared content category

/// The per-content-type policy axis is identical for subtitles and audio (anime
/// vs movie vs TV), so the audio policy reuses the same persistence-friendly
/// category the subtitle policy defines. This alias gives the audio side a
/// content-neutral name without duplicating the enum or risking the two drifting.
public typealias ContentCategory = SubtitleContentCategory

// MARK: - Audio language preference

/// What audio language a profile prefers when a title loads. Replaces the old
/// `preferOriginalLanguageAudio` boolean with a three-way choice so a profile can
/// say "original for anime, my device language for everything else" (per content
/// type, via `AudioPolicy`).
///
/// - `original`: the item's original spoken language (e.g. anime → Japanese);
///   when the original language is unknown, playback defers to the container's
///   default track (the best available proxy for "original").
/// - `device`: the viewer's device language (the dub-friendly choice).
/// - `language(code)`: an explicit ISO-639 language, regardless of original/device.
///
/// Persisted as a single string token (`"original"`, `"device"`, `"lang:<code>"`)
/// so it nests cleanly inside `PlaybackSettings` and the override map.
public enum AudioLanguagePreference: Codable, Equatable, Hashable, Sendable {
    case original
    case device
    case language(String)

    private static let originalToken = "original"
    private static let deviceToken = "device"
    private static let languagePrefix = "lang:"

    /// The explicit ISO-639 code when this is `.language`, else `nil`. Lets the
    /// resolver/UI treat the explicit-language case uniformly.
    public var explicitLanguageCode: String? {
        if case let .language(code) = self { return code }
        return nil
    }

    // MARK: Token (de)serialization

    /// The stable persistence token, also reused as a stable identity for SwiftUI
    /// option lists.
    public var token: String {
        switch self {
        case .original: return Self.originalToken
        case .device: return Self.deviceToken
        case .language(let code): return Self.languagePrefix + code
        }
    }

    /// Parses a persisted token, tolerating a bare language code (forward/back
    /// compatibility) and falling back to `.original` for anything unrecognised so
    /// a stray value never wipes the preference.
    public init(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == Self.originalToken {
            self = .original
        } else if trimmed == Self.deviceToken {
            self = .device
        } else if trimmed.hasPrefix(Self.languagePrefix) {
            let code = String(trimmed.dropFirst(Self.languagePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self = code.isEmpty ? .original : .language(code)
        } else if !trimmed.isEmpty {
            self = .language(trimmed)
        } else {
            self = .original
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(token: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

// MARK: - Policy

/// The per-profile "which audio language" brain, the audio counterpart to
/// `SubtitlePolicy`. A `basePreference` applies to everything, and an optional
/// per-`ContentCategory` override replaces it whole for that category. Pure and
/// `Codable`; the actual ordered language list still flows through the existing
/// `AudioLanguagePolicy`, which this only *feeds*.
public struct AudioPolicy: Codable, Equatable, Sendable {
    /// The profile default, applied to any category without an override.
    public var basePreference: AudioLanguagePreference
    /// Per-content-type overrides; a present entry replaces `basePreference` whole
    /// for that category. Empty (the default) means every category inherits the
    /// base, so the policy is behaviourally identical to a single global choice.
    public var overrides: [ContentCategory: AudioLanguagePreference]

    public init(
        basePreference: AudioLanguagePreference = .original,
        overrides: [ContentCategory: AudioLanguagePreference] = [:]
    ) {
        self.basePreference = basePreference
        self.overrides = overrides
    }

    /// The preference that applies to `category`: its override if present, else
    /// the profile base (mirrors `SubtitlePolicy.effectiveRule`).
    public func effectivePreference(for category: ContentCategory) -> AudioLanguagePreference {
        overrides[category] ?? basePreference
    }

    // MARK: Seeds

    /// A policy whose base mirrors the profile's `PlaybackSettings` and carries no
    /// overrides, so resolving it for any category yields exactly today's global
    /// behaviour. The behaviour-preserving default when a profile has not opted
    /// into per-content-type audio rules.
    public static func inheriting(from settings: PlaybackSettings) -> AudioPolicy {
        AudioPolicy(basePreference: settings.audioLanguagePreference)
    }

    /// The live policy for a profile: base comes from `settings`, overrides from
    /// the store. Unlike the subtitle policy, the audio preference *is* the
    /// language, so there is no frozen-language field to refresh.
    public static func resolved(
        base: AudioLanguagePreference,
        overrides: [ContentCategory: AudioLanguagePreference]
    ) -> AudioPolicy {
        AudioPolicy(basePreference: base, overrides: overrides)
    }

    /// The user's "original for anime, device language for everything else"
    /// matrix as an opt-in seed: anime keeps its original (subbed) audio while
    /// movies and TV follow the viewer's device language (favouring dubs). This
    /// is a fixed, opinionated matrix and is deliberately independent of the
    /// profile's base preference — a default profile (base `.original`) adopting
    /// it must still get dubbed movies/TV, so seeding from `base` would defeat
    /// the headline use case. NOT applied automatically — a profile adopts it
    /// deliberately, so default playback is never silently changed.
    public static func smartDefaultOverrides() -> [ContentCategory: AudioLanguagePreference] {
        [
            .anime: .original,
            .movie: .device,
            .tvShow: .device
        ]
    }
}
