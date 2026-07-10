import Foundation

// MARK: - Subtitle search accessibility preferences
//
// Mirrors the 4-level SDH (hearing-impaired) and Forced preferences that Plex's
// subtitle-search API exposes (`hearingImpaired` / `forced`, values 0–3). Modelled
// once in CoreModels so the same intent drives every backend:
//   • Plex — passed through natively as the search query parameters.
//   • Jellyfin / SMB — applied client-side (the search endpoint / file list has no
//     equivalent knob), by filtering + ranking the candidate list.
// Kept accessibility-forward: a viewer who needs SDH sets it once, per profile.

/// How hearing-impaired (SDH) subtitle candidates are treated in a search. Raw
/// values are the Plex `hearingImpaired` parameter (0–3).
public enum HearingImpairedPreference: Int, Codable, CaseIterable, Sendable {
    /// Prefer non-SDH subtitles (SDH allowed, ranked lower). Plex default.
    case preferNonSDH = 0
    /// Prefer SDH subtitles (ranked higher).
    case preferSDH = 1
    /// Only surface SDH subtitles.
    case onlySDH = 2
    /// Only surface non-SDH subtitles.
    case onlyNonSDH = 3

    /// The Plex `hearingImpaired` query value.
    public var plexParameterValue: Int { rawValue }

    public var displayName: String {
        switch self {
        case .preferNonSDH: return "Prefer Non-SDH"
        case .preferSDH: return "Prefer SDH"
        case .onlySDH: return "Only SDH"
        case .onlyNonSDH: return "Only Non-SDH"
        }
    }

    public var detail: String {
        switch self {
        case .preferNonSDH: return "Show subtitles for the deaf or hard-of-hearing lower in the list."
        case .preferSDH: return "Show subtitles for the deaf or hard-of-hearing at the top of the list."
        case .onlySDH: return "Only show subtitles for the deaf or hard-of-hearing (SDH)."
        case .onlyNonSDH: return "Never show subtitles for the deaf or hard-of-hearing."
        }
    }

    /// Whether this preference *restricts* the pool to one SDH-ness (the "Only"
    /// levels) rather than merely re-ranking.
    public var isExclusive: Bool { self == .onlySDH || self == .onlyNonSDH }

    /// Whether an SDH candidate is *allowed* under this preference (the "Only"
    /// levels filter; "Prefer" levels allow everything).
    public func allows(isHearingImpaired: Bool) -> Bool {
        switch self {
        case .onlySDH: return isHearingImpaired
        case .onlyNonSDH: return !isHearingImpaired
        case .preferSDH, .preferNonSDH: return true
        }
    }

    /// A rank contribution (higher = better) for an SDH-ness under this preference.
    public func rank(isHearingImpaired: Bool) -> Int {
        switch self {
        case .preferSDH, .onlySDH: return isHearingImpaired ? 1 : 0
        case .preferNonSDH, .onlyNonSDH: return isHearingImpaired ? 0 : 1
        }
    }
}

/// How forced subtitle candidates are treated in a search. Raw values are the
/// Plex `forced` parameter (0–3). A "forced" subtitle only covers foreign-language
/// passages (e.g. aliens speaking in a sci-fi film).
public enum ForcedSubtitlePreference: Int, Codable, CaseIterable, Sendable {
    /// Prefer non-forced (full) subtitles. Plex default.
    case preferNonForced = 0
    /// Prefer forced subtitles.
    case preferForced = 1
    /// Only surface forced subtitles.
    case onlyForced = 2
    /// Only surface non-forced subtitles.
    case onlyNonForced = 3

    public var plexParameterValue: Int { rawValue }

    public var displayName: String {
        switch self {
        case .preferNonForced: return "Prefer Non-Forced"
        case .preferForced: return "Prefer Forced"
        case .onlyForced: return "Only Forced"
        case .onlyNonForced: return "Only Non-Forced"
        }
    }

    public var detail: String {
        switch self {
        case .preferNonForced: return "Show forced (foreign-passage-only) subtitles lower in the list."
        case .preferForced: return "Show forced (foreign-passage-only) subtitles at the top of the list."
        case .onlyForced: return "Only show forced subtitles for foreign-language passages."
        case .onlyNonForced: return "Never show forced subtitles."
        }
    }

    public var isExclusive: Bool { self == .onlyForced || self == .onlyNonForced }

    public func allows(isForced: Bool) -> Bool {
        switch self {
        case .onlyForced: return isForced
        case .onlyNonForced: return !isForced
        case .preferForced, .preferNonForced: return true
        }
    }

    public func rank(isForced: Bool) -> Int {
        switch self {
        case .preferForced, .onlyForced: return isForced ? 1 : 0
        case .preferNonForced, .onlyNonForced: return isForced ? 0 : 1
        }
    }
}

/// The combined SDH + Forced search preference, applied uniformly to every
/// provider's subtitle-search results.
public struct SubtitleSearchPreference: Codable, Equatable, Sendable {
    public var hearingImpaired: HearingImpairedPreference
    public var forced: ForcedSubtitlePreference

    public init(
        hearingImpaired: HearingImpairedPreference = .preferNonSDH,
        forced: ForcedSubtitlePreference = .preferNonForced
    ) {
        self.hearingImpaired = hearingImpaired
        self.forced = forced
    }

    public static let `default` = SubtitleSearchPreference()

    /// A copy whose forced preference is overridden to "only forced" when the
    /// content-type subtitle mode is Forced-Only — so the mode and the preference
    /// can never contradict (the mode is the single source of truth for the
    /// forced-only gate; the preference only refines ranking otherwise).
    public func resolvedForcedOnly(mode: SubtitleMode) -> SubtitleSearchPreference {
        guard mode == .forcedOnly else { return self }
        return SubtitleSearchPreference(hearingImpaired: hearingImpaired, forced: .onlyForced)
    }
}
