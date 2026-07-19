import Foundation

// MARK: - Language matching

/// Small, provider-agnostic ISO-639 helper so subtitle/audio language codes can
/// be compared and normalised without pulling in any platform localisation APIs
/// at the call site. Jellyfin reports 3-letter codes (`eng`, `fra`) while the
/// device language is usually 2-letter (`en`, `fr`); both must compare equal.
public enum LanguageMatch {
    /// Common ISO-639-2 (both bibliographic *and* terminologic variants) →
    /// ISO-639-1 mappings. Not exhaustive — unknown codes pass through verbatim.
    private static let alpha3ToAlpha2: [String: String] = [
        "eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de",
        "ita": "it", "por": "pt", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh",
        "rus": "ru", "ara": "ar", "nld": "nl", "dut": "nl", "swe": "sv", "nor": "no",
        "dan": "da", "fin": "fi", "pol": "pl", "tur": "tr", "ces": "cs", "cze": "cs",
        "ell": "el", "gre": "el", "heb": "he", "hin": "hi", "tha": "th", "ukr": "uk",
        "hun": "hu", "ron": "ro", "rum": "ro", "ind": "id", "vie": "vi", "cat": "ca"
    ]

    private static let alpha2ToAlpha3: [String: String] = {
        var map: [String: String] = [:]
        // Prefer the terminologic ("t") code for the reverse direction where the
        // language has two ISO-639-2 codes (e.g. fr → fra, not fre).
        let preferred: [String: String] = [
            "fr": "fra", "de": "deu", "nl": "nld", "cs": "ces", "el": "ell", "ro": "ron", "zh": "zho"
        ]
        for (three, two) in alpha3ToAlpha2 where map[two] == nil {
            map[two] = three
        }
        for (two, three) in preferred { map[two] = three }
        return map
    }()

    /// The base language subtag, lowercased, with region/script dropped and any
    /// known 3-letter code folded to its 2-letter equivalent (`en-US` → `en`,
    /// `fra` → `fr`). Used as the canonical key for equality comparisons.
    public static func normalized(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let base = code.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? code.lowercased()
        return alpha3ToAlpha2[base] ?? base
    }

    /// Whether two language codes refer to the same language, tolerating
    /// 2-vs-3-letter and region/script differences.
    public static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let a = normalized(lhs), let b = normalized(rhs) else { return false }
        return a == b
    }

    /// Best-effort ISO-639-2 (3-letter) form of `code`, as required by some
    /// server APIs. Unknown/already-3-letter codes pass through unchanged.
    public static func alpha3(_ code: String) -> String {
        let base = code.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? code.lowercased()
        if base.count == 3 { return base }
        return alpha2ToAlpha3[base] ?? base
    }

    /// The device's current language as a 2-letter code where possible.
    public static var deviceLanguageCode: String? {
        if #available(tvOS 16, macOS 13, iOS 16, *) {
            if let code = Locale.current.language.languageCode?.identifier {
                return normalized(code)
            }
        }
        return normalized(Locale.current.identifier)
    }
}

// MARK: - Subtitle selection decision (pure, unit-tested)

/// A lightweight, platform-neutral description of one selectable subtitle
/// option, decoupled from both `MediaTrack` and AVFoundation so the selection
/// rule can be unit-tested in isolation.
public struct SubtitleCandidate: Equatable, Sendable {
    public var id: Int
    public var languageCode: String?
    public var isForced: Bool
    public var isDefault: Bool

    public init(id: Int, languageCode: String?, isForced: Bool = false, isDefault: Bool = false) {
        self.id = id
        self.languageCode = languageCode
        self.isForced = isForced
        self.isDefault = isDefault
    }
}

/// The outcome of the default subtitle-selection rule.
public enum SubtitleDecision: Equatable, Sendable {
    /// Show no subtitles (deselect any legible option).
    case none
    /// Select the candidate with this `id`.
    case select(id: Int)
}

public enum SubtitleSelector {
    /// Decides which subtitle option (if any) to enable by default for a freshly
    /// loaded item, given the user's mode and preferred language.
    ///
    /// * `.off` → never auto-enable anything (the viewer can still pick manually).
    /// * `.forcedOnly` → prefer a forced option in the preferred language, then a
    ///   forced option that is untagged or matches the active `audioLanguage`
    ///   (forced subs translate foreign dialogue *within* the audio you hear, so a
    ///   forced track in a different language is never auto-enabled when the audio
    ///   language is known), else nothing.
    /// * `.all` → prefer a non-forced option in the preferred language, then a
    ///   forced option in that language, then — only for an *untagged* default
    ///   track — the stream's default option, else nothing (a tagged
    ///   foreign-language default is never auto-enabled; auto-download, if
    ///   enabled, fetches a real match later).
    public static func decide(
        candidates: [SubtitleCandidate],
        mode: SubtitleMode,
        preferredLanguage: String?,
        audioLanguage: String? = nil
    ) -> SubtitleDecision {
        guard !candidates.isEmpty else { return .none }

        func matchingLanguage(_ candidate: SubtitleCandidate) -> Bool {
            LanguageMatch.matches(candidate.languageCode, preferredLanguage)
        }

        switch mode {
        case .off:
            return .none

        case .forcedOnly:
            let forced = candidates.filter(\.isForced)
            // A forced subtitle in the subtitle preferred language is always right.
            if let inLanguage = forced.first(where: matchingLanguage) {
                return .select(id: inLanguage.id)
            }
            // "Any forced" fallback: forced subtitles translate foreign dialogue/signs
            // *within the audio you are hearing*, so a forced track tagged for a
            // language other than the active audio (e.g. a Turkish forced track while
            // English audio plays) is wrong and must not be auto-enabled. Enable a
            // forced track only when it is untagged, matches the active audio language,
            // or when the audio language is unknown (historical behavior — we can't
            // prove the track is foreign to what the viewer hears).
            if let safeForced = forced.first(where: { candidate in
                audioLanguage == nil
                    || LanguageMatch.normalized(candidate.languageCode) == nil
                    || LanguageMatch.matches(candidate.languageCode, audioLanguage)
            }) {
                return .select(id: safeForced.id)
            }
            return .none

        case .all:
            let inLanguage = candidates.filter(matchingLanguage)
            if let full = inLanguage.first(where: { !$0.isForced }) {
                return .select(id: full.id)
            }
            if let forced = inLanguage.first {
                return .select(id: forced.id)
            }
            // No subtitle in the preferred language. Honor the container's default
            // flag ONLY when that default track carries no language tag — a flagged
            // default is the best guess for genuinely *untagged* content, and we
            // can't prove it's a language the viewer doesn't want. Never auto-enable
            // a *tagged* foreign-language subtitle the viewer didn't ask for (e.g. a
            // Chinese default for a Spanish speaker); leave subtitles off and let a
            // manual pick or background auto-download supply a real match instead.
            if let preset = candidates.first(where: {
                $0.isDefault && !$0.isForced && LanguageMatch.normalized($0.languageCode) == nil
            }) {
                return .select(id: preset.id)
            }
            return .none
        }
    }
}

// MARK: - Existing-subtitle suitability (drives auto-download)

public extension Array where Element == MediaTrack {
    /// Whether this list already contains a subtitle stream usable for
    /// `language` (any subtitle when `language` is `nil`). When `false` and
    /// auto-download is enabled, the player should fetch one in the background.
    func hasSuitableSubtitle(forLanguage language: String?) -> Bool {
        let subtitles = filter { $0.kind == .subtitle }
        guard !subtitles.isEmpty else { return false }
        guard let language, !language.isEmpty else { return true }
        return subtitles.contains { LanguageMatch.matches($0.language, language) }
    }

    /// The subtitle track that the default-selection rule would enable on load
    /// for the given `mode` / `preferredLanguage`, or `nil` for "no subtitles".
    /// Mirrors what each engine applies, but over the *provider* track list (so
    /// it can see image-based subs that AVFoundation hides), letting the router
    /// reason about which subtitle the user will actually get.
    func defaultSubtitleSelection(
        mode: SubtitleMode,
        preferredLanguage: String?,
        audioLanguage: String? = nil
    ) -> MediaTrack? {
        let subtitles = filter { $0.kind == .subtitle }
        guard !subtitles.isEmpty else { return nil }
        let candidates = subtitles.map {
            SubtitleCandidate(id: $0.id, languageCode: $0.language,
                              isForced: $0.isForced, isDefault: $0.isDefault)
        }
        guard case .select(let id) = SubtitleSelector.decide(
            candidates: candidates, mode: mode, preferredLanguage: preferredLanguage,
            audioLanguage: audioLanguage
        ) else { return nil }
        return subtitles.first { $0.id == id }
    }

    /// `true` when the subtitle that would be shown by default is **image-based**
    /// (PGS / VOBSUB / DVDSUB) *and* no equivalent text subtitle exists (same
    /// language and forced-ness). No on-device engine can render image subs, so
    /// such a file must play on the hybrid engine for the subtitle to appear.
    /// When a text equivalent exists, the native/Plozzigen engine can show that
    /// instead, so we stay there and keep its advantages (e.g. true Dolby Vision,
    /// no multichannel crash). Keyed off `isImageBasedSubtitle` — **not**
    /// a missing delivery source — so an embedded text SRT (no sidecar, but
    /// Plozzigen-renderable) is never mistaken for a bitmap sub.
    func defaultSubtitleNeedsHybridEngine(
        mode: SubtitleMode,
        preferredLanguage: String?
    ) -> Bool {
        guard let chosen = defaultSubtitleSelection(mode: mode, preferredLanguage: preferredLanguage),
              chosen.isImageBasedSubtitle else { return false }
        let hasTextEquivalent = contains {
            $0.kind == .subtitle && !$0.isImageBasedSubtitle
                && $0.isForced == chosen.isForced
                && LanguageMatch.matches($0.language, chosen.language)
        }
        return !hasTextEquivalent
    }
}

// MARK: - Remote subtitle search results

/// A subtitle a provider found on a remote subtitle service, available to be
/// downloaded onto the server. Provider-agnostic mirror of e.g. Jellyfin's
/// `RemoteSubtitleInfo`.
public struct RemoteSubtitle: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var providerName: String?
    /// Language code as reported by the service (often ISO-639-2, e.g. `eng`).
    public var language: String?
    public var format: String?
    public var communityRating: Double?
    public var downloadCount: Int?
    public var isForced: Bool
    public var isHearingImpaired: Bool

    public init(
        id: String,
        name: String,
        providerName: String? = nil,
        language: String? = nil,
        format: String? = nil,
        communityRating: Double? = nil,
        downloadCount: Int? = nil,
        isForced: Bool = false,
        isHearingImpaired: Bool = false
    ) {
        self.id = id
        self.name = name
        self.providerName = providerName
        self.language = language
        self.format = format
        self.communityRating = communityRating
        self.downloadCount = downloadCount
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
    }
}

public extension RemoteSubtitle {
    /// Common tokens in a subtitle's name/filename that mark it as hearing-impaired
    /// (SDH). Word-boundary matched so "Hindi"/"Ghibli" never false-positive on
    /// "hi". Used to enrich results from providers (Jellyfin) that don't return an
    /// explicit SDH flag.
    static func nameSuggestsHearingImpaired(_ name: String?) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        if name.contains("hearing impaired") || name.contains("hearing-impaired") { return true }
        let hiTokens: Set<String> = ["sdh", "hi", "cc", "hoh"]
        let tokens = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.contains { hiTokens.contains($0) }
    }
}

public extension Array where Element == RemoteSubtitle {
    /// Filters + ranks the results for **display** in the manual picker, honouring
    /// the SDH/Forced preference. "Only-*" levels filter the pool, "Prefer-*" levels
    /// sort. Graceful degrade: if an "Only-*" filter would empty the list, it is
    /// treated as the matching "Prefer-*" (sort, don't filter) so the viewer still
    /// sees candidates (common on Jellyfin where SDH is often unlabelled) rather
    /// than a dead-end empty screen.
    func applying(_ preference: SubtitleSearchPreference) -> [RemoteSubtitle] {
        guard !isEmpty else { return [] }
        let pool = Self.filtered(self, preference: preference)
        return pool.sorted { Self.rankKey($0, preference) > Self.rankKey($1, preference) }
    }

    /// Picks the best remote subtitle to download for `language` and the SDH/Forced
    /// `preference`. Precedence (highest first): forced-ness under the preference →
    /// SDH-ness under the preference → community rating → download count.
    ///
    /// - Parameters:
    ///   - language: preferred language (ISO code); `nil` matches any.
    ///   - mode: the content-type subtitle mode. `.forcedOnly` forces the forced
    ///     preference to "only forced" (the mode is the source of truth for the
    ///     forced-only gate; the preference refines ranking otherwise).
    ///   - preference: the SDH/Forced accessibility preference.
    ///   - requireLanguageMatch: when true, never fall back to a different-language
    ///     candidate (returns `nil` if none match) — used by auto-download so it
    ///     can't attach a wrong-language subtitle.
    func bestMatch(
        forLanguage language: String?,
        mode: SubtitleMode = .all,
        preference: SubtitleSearchPreference = .default,
        requireLanguageMatch: Bool = false
    ) -> RemoteSubtitle? {
        guard !isEmpty else { return nil }
        // Language pool.
        let languagePool: [RemoteSubtitle]
        if let language, !language.isEmpty {
            let inLanguage = filter { LanguageMatch.matches($0.language, language) }
            if requireLanguageMatch {
                languagePool = inLanguage
            } else {
                languagePool = inLanguage.isEmpty ? self : inLanguage
            }
        } else {
            languagePool = self
        }
        guard !languagePool.isEmpty else { return nil }

        let effective = preference.resolvedForcedOnly(mode: mode)
        let pool = Self.filtered(languagePool, preference: effective)
        return pool.max { Self.rankKey($0, effective) < Self.rankKey($1, effective) }
    }

    // MARK: - Preference application (shared)

    /// Applies the "Only-*" exclusive filters, with graceful degrade: a filter that
    /// would empty the pool is skipped so the caller still has candidates.
    private static func filtered(_ pool: [RemoteSubtitle], preference: SubtitleSearchPreference) -> [RemoteSubtitle] {
        var result = pool
        if preference.hearingImpaired.isExclusive {
            let f = result.filter { preference.hearingImpaired.allows(isHearingImpaired: $0.isHearingImpaired) }
            if !f.isEmpty { result = f }
        }
        if preference.forced.isExclusive {
            let f = result.filter { preference.forced.allows(isForced: $0.isForced) }
            if !f.isEmpty { result = f }
        }
        return result
    }

    /// The ordering key (higher = better) combining the preference ranks with the
    /// popularity signals. Forced-ness dominates, then SDH-ness, then rating, then
    /// downloads — so the accessibility preference always outranks a merely
    /// more-downloaded candidate.
    private static func rankKey(_ s: RemoteSubtitle, _ preference: SubtitleSearchPreference) -> (Int, Int, Double, Double) {
        (
            preference.forced.rank(isForced: s.isForced),
            preference.hearingImpaired.rank(isHearingImpaired: s.isHearingImpaired),
            s.communityRating ?? -1,
            Double(s.downloadCount ?? -1)
        )
    }
}
