import Foundation

// MARK: - Content category (CoreModels-local)

/// The subtitle-policy axis: a small, persistence-friendly content category that
/// `MetadataKit.ContentType` maps onto (so CoreModels can own the policy without
/// depending on MetadataKit). "Forced-only on movies, always-on English on anime"
/// is expressed by giving these categories different rules.
public enum SubtitleContentCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case anime
    case movie
    case tvShow
    /// Music, mixed, or unclassifiable content — always uses the profile base.
    case other
}

// MARK: - Policy

/// The per-profile "when/what" subtitle brain (design §5.3). A `basePolicy`
/// applies to everything, and an optional per-`SubtitleContentCategory` override
/// replaces it whole for that category. Pure and `Codable`; decisions still flow
/// through the existing `SubtitleSelector.decide`, which this only *feeds*.
public struct SubtitlePolicy: Codable, Equatable, Sendable {

    /// One resolved policy unit — the thing `SubtitleSelector` consumes once the
    /// per-content-type override (if any) has been applied.
    public struct Rule: Codable, Equatable, Sendable {
        /// Which subtitles to auto-enable: full vs forced-only (existing enum).
        public var mode: CaptionSettings.SubtitleMode
        /// Ordered preferred languages (ISO-639). The first is used for the
        /// on-load default selection; the rest document fallback intent for the
        /// keyless-search work that lands later.
        public var preferredLanguages: [String]
        /// Whether to search providers + ask the server to fetch a match when the
        /// preferred language is missing (the existing auto-download behaviour,
        /// now expressible per content type).
        public var autoDownloadIfMissing: Bool
        /// Second language for dual-subtitle display (e.g. anime → en primary,
        /// ja secondary). Groundwork for the dual-subs feature; unused today.
        public var secondaryLanguage: String?

        public init(
            mode: CaptionSettings.SubtitleMode = .all,
            preferredLanguages: [String] = [],
            autoDownloadIfMissing: Bool = false,
            secondaryLanguage: String? = nil
        ) {
            self.mode = mode
            self.preferredLanguages = preferredLanguages
            self.autoDownloadIfMissing = autoDownloadIfMissing
            self.secondaryLanguage = secondaryLanguage
        }

        /// The single preferred language fed to `SubtitleSelector.decide` for the
        /// on-load default (the first entry), or `nil` to follow the device/none.
        public var preferredLanguage: String? { preferredLanguages.first }

        /// Feeds this rule into the existing pure selector so the policy never
        /// re-implements the selection logic — it only chooses the inputs.
        public func decision(candidates: [SubtitleCandidate]) -> SubtitleDecision {
            SubtitleSelector.decide(
                candidates: candidates,
                mode: mode,
                preferredLanguage: preferredLanguage
            )
        }
    }

    /// The profile default, applied to any category without an override.
    public var basePolicy: Rule
    /// Per-content-type overrides; a present entry replaces `basePolicy` whole
    /// for that category. Empty (the default) means every category inherits the
    /// base, so the policy is behaviourally identical to a single global rule.
    public var overrides: [SubtitleContentCategory: Rule]

    public init(basePolicy: Rule = Rule(), overrides: [SubtitleContentCategory: Rule] = [:]) {
        self.basePolicy = basePolicy
        self.overrides = overrides
    }

    /// The rule that applies to `category`: its override if present, else the
    /// profile base (design §5.0 — `overrides[type] ?? basePolicy`).
    public func effectiveRule(for category: SubtitleContentCategory) -> Rule {
        overrides[category] ?? basePolicy
    }

    // MARK: Seeds

    /// A policy whose base mirrors the current `CaptionSettings` and carries no
    /// overrides, so resolving it for any category yields exactly today's global
    /// behaviour. The behaviour-preserving default when a profile has not opted
    /// into per-content-type rules.
    public static func inheriting(from caption: CaptionSettings) -> SubtitlePolicy {
        let languages = caption.resolvedPreferredLanguage.map { [$0] } ?? []
        return SubtitlePolicy(
            basePolicy: Rule(
                mode: caption.subtitleMode,
                preferredLanguages: languages,
                autoDownloadIfMissing: caption.autoDownloadSubtitles
            )
        )
    }

    /// The user's example matrix as an opt-in seed (design §5.3): forced-only for
    /// movies, full subs for anime/TV, anime auto-downloading a missing match.
    /// Languages default to `base.preferredLanguages` (falling back to English)
    /// so the seed honours the viewer's language choice. NOT applied
    /// automatically — a profile adopts it deliberately, so default playback is
    /// never silently changed.
    public static func smartDefaultOverrides(base: Rule) -> [SubtitleContentCategory: Rule] {
        let languages = base.preferredLanguages.isEmpty ? ["en"] : base.preferredLanguages
        return [
            .anime: Rule(mode: .all, preferredLanguages: languages, autoDownloadIfMissing: true),
            .movie: Rule(mode: .forcedOnly, preferredLanguages: languages, autoDownloadIfMissing: false),
            .tvShow: Rule(mode: .all, preferredLanguages: languages, autoDownloadIfMissing: false)
        ]
    }
}
