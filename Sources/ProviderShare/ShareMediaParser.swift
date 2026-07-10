import Foundation
import CoreModels

/// Best-effort parsing of media *filenames* into structured metadata. A media
/// share has no server telling us what a file is, so we infer it the way Infuse
/// / Plex "scanners" do: from the name (and a little from the folder above it).
///
/// This is deliberately conservative and heuristic — Phase 2c layers a real
/// metadata provider (TMDb) on top to fix up titles/years. For slice (a) it just
/// needs to be good enough to group episodes under a show and give movies a
/// clean title + year.
enum ShareMediaParser {
    /// File extensions we treat as playable video.
    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts",
        "wmv", "mpg", "mpeg", "flv", "ogv", "3gp",
    ]

    static func isVideoFile(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// File extensions we treat as text subtitle sidecars (the overlay can parse
    /// these). Image-based sidecars (`.sup`/`.idx`+`.sub`) are excluded — no
    /// on-device engine renders them from a bare share.
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    static func isSubtitleFile(_ name: String) -> Bool {
        subtitleExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A parsed sidecar subtitle filename: the video "stem" it belongs to plus the
    /// language / forced / SDH hints teased out of the dotted suffix tokens
    /// (`Movie (2009).en.forced.srt` → stem `Movie (2009)`, language `en`, forced).
    struct Sidecar: Equatable {
        var stem: String
        var language: String?
        var isForced: Bool
        var isSDH: Bool
        var ext: String
    }

    /// ISO-ish subtitle-suffix tokens that are NOT a language (so they don't get
    /// mistaken for one). Matched case-insensitively, word-for-word.
    private static let sidecarFlagTokens: Set<String> = [
        "forced", "foreign", "sdh", "hi", "cc", "hoh", "full", "default"
    ]

    /// Parses a subtitle filename into its `Sidecar` parts. Returns `nil` when the
    /// file isn't a text subtitle. The stem is everything before the first
    /// recognised suffix token (language or flag), so it can be matched against a
    /// video file's own stem in the same directory.
    static func parseSidecar(_ name: String) -> Sidecar? {
        let ns = name as NSString
        let ext = ns.pathExtension.lowercased()
        guard subtitleExtensions.contains(ext) else { return nil }
        let base = ns.deletingPathExtension
        var tokens = base.split(separator: ".").map(String.init)
        guard !tokens.isEmpty else { return nil }

        var language: String?
        var isForced = false
        var isSDH = false
        // Consume trailing dotted tokens that look like language/flag qualifiers,
        // leaving the leading tokens as the stem. Walk from the end so
        // "Movie.Name.en.sdh" keeps "Movie.Name" as the stem.
        while tokens.count > 1 {
            let token = tokens[tokens.count - 1]
            let lower = token.lowercased()
            if sidecarFlagTokens.contains(lower) {
                if lower == "forced" || lower == "foreign" { isForced = true }
                if lower == "sdh" || lower == "hi" || lower == "cc" || lower == "hoh" { isSDH = true }
                tokens.removeLast()
                continue
            }
            if language == nil, let code = normalizedSubtitleLanguage(lower) {
                language = code
                tokens.removeLast()
                continue
            }
            break
        }
        let stem = tokens.joined(separator: ".")
        return Sidecar(stem: stem, language: language, isForced: isForced, isSDH: isSDH, ext: ext)
    }

    /// The video "stem" of a video filename (basename without its extension), used
    /// to match sibling sidecars by name.
    static func videoStem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    /// Whether `token` is a plausible subtitle language code (2- or 3-letter, or a
    /// known English language name), returning its normalised 2-letter form.
    private static func normalizedSubtitleLanguage(_ token: String) -> String? {
        // Full English name (e.g. "english", "spanish").
        if let match = SubtitleLanguageCatalog.languages.first(where: { $0.name.lowercased() == token }) {
            return match.code
        }
        // 2/3-letter ISO code. Require it to normalise to a known base to avoid
        // treating a random 2-3 char token (e.g. a release group) as a language.
        guard token.count == 2 || token.count == 3 else { return nil }
        guard let normalized = LanguageMatch.normalized(token) else { return nil }
        // Only accept when it's a code we recognise, or the token was already a
        // clean alpha string of the right length that folded to a 2-letter base.
        let isKnown = SubtitleLanguageCatalog.languages.contains { $0.code == normalized }
        let looksLikeCode = token.allSatisfy { $0.isLetter }
        return (isKnown || (looksLikeCode && normalized.count == 2)) ? normalized : nil
    }

    struct Episode: Equatable {
        var series: String
        var season: Int
        var episode: Int
        /// Episode title when the name carried one after the SxxEyy token.
        var title: String?
    }

    struct Movie: Equatable {
        var title: String
        var year: Int?
    }

    // SxxEyy / SxxExyy, 1x02, and "Season 1 Episode 2" style markers. The `NxM`
    // form is digit-boundary-anchored (`(?<![0-9])…(?![0-9])`) so a raw resolution
    // like `1920x1080` in a home-video filename can't backtrack into a bogus
    // "S20·E108" match — only a genuine `1x02`-style token qualifies.
    private static let episodePatterns: [NSRegularExpression] = {
        let raw = [
            #"[sS](\d{1,2})[\s._-]*[eE](\d{1,3})"#,
            #"(?<![0-9])(\d{1,2})x(\d{1,3})(?![0-9])"#,
            #"[sS]eason[\s._-]*(\d{1,2})[\s._-]*[eE]pisode[\s._-]*(\d{1,3})"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    // A 4-digit year, not embedded in a longer number and not the width of a
    // `1920x1080`/`2048x…` resolution or a `2160p`-style tag (trailing
    // `[0-9xXpiPI]` excluded), so a resolution can't be misread as the year.
    private static let yearPattern = try! NSRegularExpression(pattern: #"(?<![0-9])(19|20)\d{2}(?![0-9xXpiPI])"#)

    /// Classify a video file (given its name and the immediate parent folder
    /// name, which helps recover a series title the filename abbreviates).
    static func classify(fileName: String, parentFolder: String?) -> Kind {
        let stem = (fileName as NSString).deletingPathExtension
        if let ep = parseEpisode(stem: stem, parentFolder: parentFolder) {
            return .episode(ep)
        }
        return .movie(parseMovie(stem: stem, parentFolder: parentFolder))
    }

    enum Kind: Equatable {
        case movie(Movie)
        case episode(Episode)
    }

    // MARK: - Episode

    static func parseEpisode(stem: String, parentFolder: String?) -> Episode? {
        let ns = stem as NSString
        let full = NSRange(location: 0, length: ns.length)
        for regex in episodePatterns {
            guard let m = regex.firstMatch(in: stem, range: full), m.numberOfRanges >= 3,
                  let season = Int(ns.substring(with: m.range(at: 1))),
                  let episode = Int(ns.substring(with: m.range(at: 2))) else { continue }

            // Series name = the text before the marker, cleaned. If that's empty
            // (the file is just "S01E02"), fall back to the parent folder — but
            // strip a trailing "Season N" so we get the show, not the season.
            let before = ns.substring(to: m.range.location)
            var series = clean(before)
            if series.isEmpty {
                series = seriesFromFolder(parentFolder) ?? "Unknown"
            }

            // Episode title = whatever trails the marker, cleaned (often junk /
            // release tags — kept only if it looks like words, not a scene tag).
            let afterStart = m.range.location + m.range.length
            let after = afterStart < ns.length ? ns.substring(from: afterStart) : ""
            let title = episodeTitle(from: after)

            return Episode(series: series, season: season, episode: episode, title: title)
        }
        return nil
    }

    private static func seriesFromFolder(_ folder: String?) -> String? {
        guard let folder, !folder.isEmpty else { return nil }
        // A "Season 3" folder tells us the season, not the show; the show is its
        // parent, which the caller passes as the grandparent when it can. Here we
        // just avoid returning "Season 3" as a title.
        if folder.range(of: #"^[Ss]eason\s*\d+$"#, options: .regularExpression) != nil { return nil }
        if folder.range(of: #"^[Ss]\d+$"#, options: .regularExpression) != nil { return nil }
        let cleaned = clean(folder)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func episodeTitle(from raw: String) -> String? {
        let cleaned = clean(raw)
        guard !cleaned.isEmpty else { return nil }
        // Release names put the real episode title first, then scene/quality tags
        // ("Pilot 720p WEB-DL x264"). Keep words up to the first tag so we show
        // "Pilot", not "Pilot 720p". Require at least one real (non-numeric) word.
        let tags: Set<String> = [
            "1080p", "720p", "2160p", "480p", "4k", "web", "webdl",
            "bluray", "hdtv", "x264", "x265", "hevc", "aac", "ddp", "dd", "amzn",
            "nf", "dsnp", "hmax", "atvp", "repack", "proper", "internal",
        ]
        var kept: [String] = []
        for word in cleaned.split(separator: " ").map(String.init) {
            // Match hyphen-insensitively so tight scene spellings like "WEB-DL"
            // (which `clean` leaves intact — it only splits space-flanked dashes)
            // still cut the title, not just the space-separated forms.
            let normalized = word.lowercased().replacingOccurrences(of: "-", with: "")
            if tags.contains(word.lowercased()) || tags.contains(normalized) { break }
            kept.append(word)
        }
        let meaningful = kept.filter { $0.count >= 2 && Int($0) == nil }
        guard !meaningful.isEmpty else { return nil }
        return kept.joined(separator: " ")
    }

    // MARK: - Movie

    static func parseMovie(stem: String, parentFolder: String?) -> Movie {
        let ns = stem as NSString
        let full = NSRange(location: 0, length: ns.length)
        // Use the LAST year match (titles like "2001 A Space Odyssey 1968" → 1968
        // is the release year, which appears after the title).
        var year: Int?
        var titleCut = ns.length
        let matches = yearPattern.matches(in: stem, range: full)
        if let last = matches.last {
            year = Int(ns.substring(with: last.range))
            titleCut = last.range.location
        }
        var title = clean(ns.substring(to: titleCut))
        if title.isEmpty {
            title = clean(parentFolder ?? "") 
        }
        if title.isEmpty { title = stem }
        return Movie(title: title, year: year)
    }

    // MARK: - Cleaning

    /// Turn a raw filename fragment into a display title: separators → spaces,
    /// bracketed groups removed, collapsed whitespace, trimmed trailing dashes.
    static func clean(_ raw: String) -> String {
        var s = raw
        // Strip [...] and (...) groups (release group tags, quality in parens).
        s = s.replacingOccurrences(of: #"[\[\(\{][^\]\)\}]*[\]\)\}]"#, with: " ", options: .regularExpression)
        // Strip resolution tokens (1920x1080, 1280x720, 1080p, 480i, …) so they
        // never survive into a displayed title.
        s = s.replacingOccurrences(of: #"\b\d{3,4}\s*[xX]\s*\d{3,4}\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b\d{3,4}[piPI]\b"#, with: " ", options: .regularExpression)
        // Common separators to spaces.
        s = s.replacingOccurrences(of: ".", with: " ")
             .replacingOccurrences(of: "_", with: " ")
        // A dash flanked by spaces is a separator; keep hyphenated words intact.
        s = s.replacingOccurrences(of: " - ", with: " ")
        // Drop any stray/unbalanced bracket chars a group-strip left behind (e.g.
        // a title like "Inception (2010)" cut at the year leaves a dangling "(").
        s = s.replacingOccurrences(of: #"[\[\]\(\)\{\}]"#, with: " ", options: .regularExpression)
        // Collapse whitespace.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }
}
