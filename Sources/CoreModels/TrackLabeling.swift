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

    /// A short, human audio **format** hint from codec + channel layout, e.g.
    /// "DTS 7.1", "Dolby TrueHD 5.1", "AAC Stereo", or "Dolby Atmos". Lets an
    /// untagged track read as "Track 1 (DTS 7.1)" instead of a bare "Track 1".
    /// Returns `nil` only when neither codec nor channel count is known.
    public static func audioFormatHint(codec: String?, channels: Int?, isAtmos: Bool) -> String? {
        let codecName = audioCodecName(codec)
        // Atmos is object-based; the bed channel count is misleading, so surface
        // the format alone (matching how Plex/AppleTV present it).
        if isAtmos { return "Dolby Atmos" }
        let layout = channelLayoutName(channels)
        switch (codecName, layout) {
        case let (codec?, layout?): return "\(codec) \(layout)"
        case let (codec?, nil): return codec
        case let (nil, layout?): return layout
        case (nil, nil): return nil
        }
    }

    /// Recognizable display name for a libavcodec/container audio codec token.
    private static func audioCodecName(_ codec: String?) -> String? {
        guard let token = codec?.lowercased(), !token.isEmpty else { return nil }
        switch token {
        case "ac3": return "Dolby Digital"
        case "eac3", "ec3", "ec-3": return "Dolby Digital+"
        case "truehd", "mlp": return "Dolby TrueHD"
        case "dts", "dca", "dts-hd", "dtshd": return "DTS"
        case "aac", "aac_latm": return "AAC"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "mp3", "mp2", "mp1": return token.uppercased()
        case "wmav2", "wmapro", "wmav1": return "WMA"
        default:
            if token.hasPrefix("pcm") { return "PCM" }
            return token.uppercased()
        }
    }

    /// Friendly channel-layout label for a channel count (`2` → "Stereo",
    /// `6` → "5.1"). `nil`/`0` yields no label.
    private static func channelLayoutName(_ channels: Int?) -> String? {
        guard let channels, channels > 0 else { return nil }
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 3: return "2.1"
        case 4: return "4.0"
        case 5: return "5.0"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
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
        isHearingImpaired: Bool = false,
        isCommentary: Bool = false,
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
        // Prefer the reliable container flag; fall back to the title-text heuristic.
        if isHearingImpaired || Self.isHearingImpaired(displayTitle) { qualifiers.append("SDH") }
        if isCommentary { qualifiers.append("Commentary") }
        if let hint = subtitleFormatHint(codec: codec, isImageBased: isImageBased) {
            qualifiers.append(hint)
        }
        if providerName == nil, detectedName != nil { qualifiers.append("auto") }

        guard !qualifiers.isEmpty else { return base }
        return "\(base) (\(qualifiers.joined(separator: ", ")))"
    }

    /// Builds the audio menu label. Leads with the resolved **language** (like
    /// Plex's "Japanese (OPUS 5.1)") because provider audio titles are often a
    /// release/encoder tag that omits the language entirely ("[HR] 5.1 Channels
    /// (Doc_Ramen)") — returning such a title wholesale would hide the language.
    /// A provider title that already *names* the language is kept as-is (it's a
    /// complete human label, e.g. "English - Dolby Digital - 5.1"); otherwise the
    /// language leads and is annotated with the audio format ("DTS 7.1") and a
    /// Commentary marker. Falls back to a meaningful title, then "Track N", only
    /// when no language resolves.
    public static func audioLabel(
        displayTitle: String,
        language: String?,
        codec: String? = nil,
        channels: Int? = nil,
        isAtmos: Bool = false,
        isCommentary: Bool = false,
        trackID: Int
    ) -> String {
        let languageNm = languageName(forCode: language)

        // A provider title that already names the language is a complete label.
        if let languageNm,
           !isGenericTitle(displayTitle),
           displayTitle.range(of: languageNm, options: .caseInsensitive) != nil {
            return displayTitle
        }

        let base: String
        if let languageNm {
            base = languageNm
        } else if !isGenericTitle(displayTitle) {
            // No language, but the title says something real — trust it as-is.
            return displayTitle
        } else {
            base = "Track \(trackID)"
        }

        var qualifiers: [String] = []
        if let hint = audioFormatHint(codec: codec, channels: channels, isAtmos: isAtmos) {
            qualifiers.append(hint)
        }
        if isCommentary { qualifiers.append("Commentary") }

        guard !qualifiers.isEmpty else { return base }
        return "\(base) (\(qualifiers.joined(separator: ", ")))"
    }
}

// MARK: - Enriching demuxer tracks with provider metadata

public extension MediaTrack {
    /// Returns a copy of this demuxer/engine track enriched with metadata from a
    /// matching provider track (the media server's probe of the *same* file).
    ///
    /// The advanced engine demuxes tracks straight from the container, so an
    /// untagged file yields bare names ("Track 8") and a `nil` language. The
    /// provider (Plex/Jellyfin) frequently probes the same streams with richer
    /// tags. We trust the engine wherever it already has a value and only *fill
    /// gaps* from the provider — never overwriting real engine data — so an
    /// already-labelled track is left untouched. Callers match the provider track
    /// by stream `id`; when the two id spaces don't line up there is simply no
    /// match (`provider == nil`) and nothing changes.
    func enriched(withProvider provider: MediaTrack?) -> MediaTrack {
        guard let provider else { return self }
        var merged = self
        if merged.language == nil { merged.language = provider.language }
        if merged.codec == nil { merged.codec = provider.codec }
        if merged.channels == nil { merged.channels = provider.channels }
        if !merged.isForced { merged.isForced = provider.isForced }
        if !merged.isAtmos { merged.isAtmos = provider.isAtmos }
        if !merged.isHearingImpaired { merged.isHearingImpaired = provider.isHearingImpaired }
        if !merged.isCommentary { merged.isCommentary = provider.isCommentary }
        // Only adopt the provider's title to replace a *generic* engine title,
        // and only when the provider's own title actually says something.
        if TrackLabeling.isGenericTitle(merged.displayTitle),
           !TrackLabeling.isGenericTitle(provider.displayTitle) {
            merged.displayTitle = provider.displayTitle
        }
        return merged
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
