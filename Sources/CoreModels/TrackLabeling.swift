import Foundation

// MARK: - Human-friendly track labels + menu ordering

/// Provider-agnostic, pure (Foundation-only) helpers that turn raw `MediaTrack`
/// facts (language code, codec, forced/default flags, a possibly-generic
/// `displayTitle`) into a clean menu label, and order a list of tracks so the
/// viewer's preferred languages come first.
///
/// Kept in `CoreModels` and AVFoundation/SwiftUI-free so it's unit-testable and
/// usable from both the in-player menu and any provider. The player adds an
/// opportunistic *content-based* language guess (e.g. `NLLanguageRecognizer`
/// over parsed cues) on top, passed in via `detectedLanguage`.
public enum TrackLabeling {

    /// A localized, Title-cased language **name** for an ISO-639 code
    /// (`"en"`/`"eng"` → `"English"`). `nil` for nil/empty/unresolvable codes.
    public static func languageName(forCode code: String?) -> String? {
        guard let normalized = LanguageMatch.normalized(code), !normalized.isEmpty else { return nil }
        guard let name = Locale.current.localizedString(forLanguageCode: normalized),
              !name.isEmpty,
              // Locale echoes the code back for unknown languages; reject that so
              // we fall through to the provider title instead of showing "Qaa".
              name.lowercased() != normalized.lowercased() else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A short uppercase format hint for an image/subtitle codec token, or `nil`
    /// when nothing useful can be said. Text codecs return `nil` (the language is
    /// the useful fact); image codecs surface their family so a bitmap track
    /// reads as "Spanish (PGS)" rather than a bare "Track 8".
    public static func subtitleFormatHint(codec: String?, isImageBased: Bool) -> String? {
        let token = (codec ?? "").lowercased()
        if token.contains("pgs") { return "PGS" }
        if token.contains("vob") { return "VobSub" }
        if token.contains("dvd") { return "DVD" }
        if token.contains("dvb") { return "DVB" }
        // Unknown image codec: still signal it's a bitmap so the viewer knows
        // why there's no language and that it can't be restyled.
        if isImageBased { return "Image" }
        return nil
    }

    /// Whether a provider/demuxer title looks *generic* — i.e. carries no real
    /// information beyond an index/codec ("Track 8", "Subtitle 3 (pgssub)",
    /// "subrip"). Such titles are dropped in favour of a resolved language name
    /// or a clean "Track N".
    public static func isGenericTitle(_ title: String?) -> Bool {
        guard let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return true }
        var token = raw.lowercased()
        // Strip a trailing "(codec)" annotation, e.g. "track 8 (pgssub)".
        if let paren = token.firstIndex(of: "(") {
            token = String(token[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        // Drop leading "track"/"subtitle"/"stream"/"sub"/"audio" + number/codec.
        for prefix in ["track", "subtitle", "stream", "audio", "sub"] where token.hasPrefix(prefix) {
            let rest = token.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.allSatisfy({ $0.isNumber }) { return true }
        }
        if token.isEmpty || token.allSatisfy({ $0.isNumber }) { return true }
        // A bare codec token on its own carries no language/intent.
        let codecTokens: Set<String> = [
            "subrip", "srt", "ass", "ssa", "webvtt", "vtt", "mov_text", "text", "ttml",
            "subviewer", "sami", "smi", "pgssub", "hdmv_pgs_subtitle", "dvd_subtitle",
            "dvdsub", "vobsub", "dvb_subtitle", "und", "unknown"
        ]
        return codecTokens.contains(token)
    }

    /// Hearing-impaired / SDH heuristic from a provider title (we have no flag).
    public static func isHearingImpaired(_ title: String?) -> Bool {
        let token = (title ?? "").lowercased()
        return token.contains("sdh")
            || token.contains("hearing impaired")
            || token.contains("hard of hearing")
            || token.range(of: #"(^|\W)cc(\W|$)"#, options: .regularExpression) != nil
    }

    /// Builds the subtitle menu label for a track. Prefers a resolved language
    /// name (provider language first, else a content-detected guess), then a
    /// meaningful provider title, else "Track N". Appends qualifiers in
    /// parentheses: Forced, SDH, an image-format hint, and "auto" when the
    /// language came only from on-device content detection.
    public static func subtitleLabel(
        displayTitle: String,
        language: String?,
        codec: String?,
        isForced: Bool,
        isImageBased: Bool,
        detectedLanguage: String? = nil,
        trackID: Int
    ) -> String {
        let providerName = languageName(forCode: language)
        let detectedName = providerName == nil ? languageName(forCode: detectedLanguage) : nil
        let base: String
        if let providerName {
            base = providerName
        } else if let detectedName {
            base = detectedName
        } else if !isGenericTitle(displayTitle) {
            base = displayTitle
        } else {
            base = "Track \(trackID)"
        }

        var qualifiers: [String] = []
        if isForced { qualifiers.append("Forced") }
        if isHearingImpaired(displayTitle) { qualifiers.append("SDH") }
        if let hint = subtitleFormatHint(codec: codec, isImageBased: isImageBased) {
            qualifiers.append(hint)
        }
        if providerName == nil, detectedName != nil { qualifiers.append("auto") }

        guard !qualifiers.isEmpty else { return base }
        return "\(base) (\(qualifiers.joined(separator: ", ")))"
    }

    /// Builds the audio menu label. Provider audio titles are usually rich
    /// ("English - Dolby Digital - 5.1"), so a meaningful one is kept as-is; only
    /// generic ones are replaced with the resolved language name (or "Track N").
    public static func audioLabel(
        displayTitle: String,
        language: String?,
        trackID: Int
    ) -> String {
        if !isGenericTitle(displayTitle) { return displayTitle }
        if let name = languageName(forCode: language) { return name }
        return "Track \(trackID)"
    }
}

// MARK: - Preferred-language menu ordering

public extension Array where Element == MediaTrack {
    /// Returns the tracks reordered so any whose language matches the viewer's
    /// `preferredLanguages` (in priority order) sort to the top, preserving the
    /// original relative order within each rank (stable). Tracks with no
    /// preferred-language match keep their provider order after the preferred
    /// ones. Pass the resolved preferred language first, then fallbacks (e.g. the
    /// device language).
    func sortedByPreferredLanguage(_ preferredLanguages: [String?]) -> [MediaTrack] {
        let prefs = preferredLanguages
            .compactMap { LanguageMatch.normalized($0) }
            .reduce(into: [String]()) { acc, code in if !acc.contains(code) { acc.append(code) } }
        guard !prefs.isEmpty else { return self }

        func rank(_ track: MediaTrack) -> Int {
            guard let code = LanguageMatch.normalized(track.language) else { return prefs.count }
            return prefs.firstIndex(of: code) ?? prefs.count
        }

        return enumerated()
            .sorted { lhs, rhs in
                let lr = rank(lhs.element), rr = rank(rhs.element)
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset   // stable within a rank
            }
            .map(\.element)
    }
}
