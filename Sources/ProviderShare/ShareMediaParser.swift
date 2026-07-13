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
    /// Bumped whenever the movie/episode CLASSIFICATION rules (or the keys derived
    /// from them) change, so a share's catalog can force a one-time full re-walk
    /// that reclassifies every already-indexed file under the new rules instead of
    /// waiting for each file to change on disk. See `ShareScanner.scanIfStale`.
    /// v9: anchor a series to its show folder (override filename variant prefixes
    /// and redundant nested season/variant subfolders).
    /// v10: normalize series titles (strip year/season/edition/quality junk),
    /// prefer the clean filename title over a junky folder, and capture the series
    /// year — collapses split/variant folders and fixes same-name matches.
    static let classifierVersion = 14

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
        /// Release year of the SERIES, recovered from the filename/folder (e.g.
        /// `Show (2024)`), used to disambiguate same-name shows at enrichment.
        var year: Int?
        /// An EXPLICIT external id embedded in the folder/filename by the user's
        /// media manager (Plex/Jellyfin/Sonarr style `[tvdb-81797]`, `{tmdb-123}`),
        /// normalized as `source-number`. The strongest possible signal: it keeps a
        /// genuinely different same-named show apart (One Piece anime `[tvdb-81797]`
        /// vs the live-action reboot) and can seed authoritative enrichment.
        var providerTag: String?
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
    ///
    /// Filename-only fallback kept for callers/tests without a full path; the
    /// production paths use ``classify(relPath:)``, which also weighs the folder
    /// tree — the strongest real-world signal (how Plex/Jellyfin/Infuse decide).
    static func classify(fileName: String, parentFolder: String?) -> Kind {
        let stem = (fileName as NSString).deletingPathExtension
        if let ep = parseEpisode(stem: stem, parentFolder: parentFolder) {
            // No folder tree here, so the immediate parent is the only fallback
            // when the filename carried no series title.
            return .episode(resolveSeries(ep, showFolder: parentFolder))
        }
        return .movie(parseMovie(stem: stem, parentFolder: parentFolder))
    }

    /// Classify a video file from its full share-relative path, using the FOLDER
    /// TREE as the primary signal and the filename as the secondary one — the way
    /// real media scanners work. Media shares are organised
    /// (`Movies/…`, `TV/Show/Season 1/…`, `Anime/Show/…`), so the folder resolves
    /// the movie-vs-episode ambiguity a bare filename can't (e.g. anime named
    /// `Sword Art Online II - 18.mkv` with no `SxxEyy` marker).
    ///
    /// Precedence (high → low):
    ///  1. Explicit filename episode marker (`SxxEyy`, `1x02`, `Season N Episode M`).
    ///  2. A `Season N`/`SNN`/`Staffel N`/`Specials` ancestor, OR a series library
    ///     root (`TV`, `TV Shows`, `Shows`, `Series`, `Anime`, …) → accept a BARE
    ///     episode number the marker patterns reject. TV/season context beats the
    ///     movie-folder guard.
    ///  3. A `Title (Year)` movie folder or a movie library root
    ///     (`Movies`, `Films`, `Anime Movies`, …) → movie.
    ///  4. Fallback: filename heuristic (a year ⇒ movie).
    static func classify(relPath: String) -> Kind {
        let comps = relPath.split(separator: "/").map(String.init)
        guard let fileName = comps.last else {
            return .movie(Movie(title: relPath, year: nil))
        }
        let stem = (fileName as NSString).deletingPathExtension
        let ancestors = Array(comps.dropLast())            // folders, root-first
        let showHint = seriesHintFolder(fromAncestors: ancestors)
        // The authoritative show folder (outermost, above any season folder), used
        // to resolve the series when the FILENAME carries no usable title — a
        // "S01E01 - Title.mkv" file, or a nested/variant subfolder. When the
        // filename DOES carry a title we prefer it (it's usually the cleanest
        // signal); see `resolveSeries`.
        let showFolder = authoritativeShowFolder(fromAncestors: ancestors)
        let providerTag = embeddedProviderTag(relPath: relPath)
        let nestedSubShow = nestedSubShowPresent(ancestors: ancestors, showFolder: showFolder)

        // (1) Explicit episode marker — strongest, works in any folder.
        if let ep = parseEpisode(stem: stem, parentFolder: showHint) {
            return .episode(resolveSeries(ep, showFolder: showFolder, providerTag: providerTag,
                                          allowNestedSubShow: nestedSubShow))
        }

        // (2) Folder says "this is a series" → accept a bare episode number.
        let seasonAncestor = ancestors.last(where: isSeasonFolder)
        let context = libraryContext(ancestors)
        if seasonAncestor != nil || context == .seriesLibrary {
            if let ep = parseBareEpisode(stem: stem, seasonFolder: seasonAncestor, showFolder: showHint) {
                if seasonAncestor == nil {
                    let fileMovie = parseMovie(stem: stem, parentFolder: nil)
                    if fileMovie.year != nil,
                       fileMovie.title.unicodeScalars.contains(where: CharacterSet.letters.contains),
                       title(fileMovie.title, containsStandaloneNumber: ep.episode) {
                        return .movie(fileMovie)
                    }
                }
                // Mixed Anime/Series roots often contain films too. A year-bearing
                // parent folder is a movie signal when the apparent episode number
                // is actually part of that parent title ("Ghost in the Shell 2",
                // "Blade Runner 2049"). A new number absent from the parent remains
                // an episode (`TV/Show (2024)/Show 01.mkv`).
                if seasonAncestor == nil,
                   let parent = ancestors.last,
                   yearBearingMovieFolder(parent, containsTitleNumber: ep.episode) {
                    return .movie(parseMovie(stem: stem, parentFolder: parent))
                }
                return .episode(resolveSeries(ep, showFolder: showFolder, providerTag: providerTag,
                                              allowNestedSubShow: nestedSubShow))
            }
        }

        // (3)/(4) Movie: a `Title (Year)` folder / movie library root, or the
        // filename fallback. `ancestors.last` gives the movie folder its year/title
        // when the filename lacks them (`Star Wars (1977)/movie.mkv`).
        return .movie(parseMovie(stem: stem, parentFolder: ancestors.last))
    }

    /// An explicit external id embedded in a share-relative path by a media manager
    /// (Plex/Jellyfin/Sonarr conventions): `[tvdb-81797]`, `{tmdb-1399}`,
    /// `[imdb-tt0944947]`, `[anidb-69]`, `tvdbid=81797`. Normalized to
    /// `source-number` (e.g. `tvdb-81797`), preferring the strongest source. Nil
    /// when the path carries none. Case-insensitive.
    static func embeddedProviderTag(relPath: String) -> String? {
        let sources = ["tvdb", "tmdb", "imdb", "anidb", "tvmaze", "anilist"]
        var found: [String: String] = [:]
        for src in sources {
            let pattern = "[\\[{(]\\s*\(src)(?:id)?[-_=:]?\\s*(tt)?(\\d+)\\s*[\\]})]"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = relPath as NSString
            if let m = regex.firstMatch(in: relPath, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges >= 3 {
                let tt = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
                let num = ns.substring(with: m.range(at: 2))
                found[src] = "\(src)-\(tt)\(num)".lowercased()
            }
        }
        // Prefer the most authoritative source present.
        for src in sources { if let tag = found[src] { return tag } }
        return nil
    }

    /// Resolves an episode's final series name + year for GROUPING and display.
    /// Prefers the normalized SHOW FOLDER title: normalization cleans junk/variant
    /// folders ("Deadloch.cc"→"Deadloch", "…(2022) Season 1 S01 (…)"→"House of the
    /// Dragon"), so a show split across differently-named folders collapses into
    /// ONE series, while genuinely different same-named shows in distinctly-named
    /// folders stay separate (the user's animated "Avatar the Last Airbender"
    /// folder vs the live-action "Avatar (2024)" folder). Falls back to the
    /// filename-derived title only when there's no authoritative show folder (a
    /// loose "Downloads/Show S01E01.mkv"). The generic-folder case (Avatar (2024) →
    /// "Avatar") is handled at enrichment, which also searches the richer filename
    /// title. Year = filename (usually explicit) else folder.
    private static func resolveSeries(_ ep: Episode, showFolder: String?, providerTag: String? = nil,
                                     allowNestedSubShow: Bool = false) -> Episode {
        var ep = ep
        let folder = showFolder.map(normalizeSeriesTitleAndYear)
        let folderTitle = folder?.title ?? ""
        let fileTitle = ep.series   // filename-derived, already normalized in parse
        // Nested sub-show: the file sits in a non-season subfolder BELOW the show
        // folder AND its filename names a MORE-SPECIFIC series that extends the show
        // folder title ("The Witcher/Blood Origin/The Witcher Blood Origin SxxEyy").
        // Prefer the filename so the spinoff groups on its own (and merges with a
        // sibling "The Witcher Blood Origin" folder) instead of being absorbed into
        // the parent — while an ordinary variant prefix ("Arrested Development
        // Remix", stripped by normalization to the show name) still folds in.
        if allowNestedSubShow, !fileTitle.isEmpty,
           titleStrictlyExtends(fileTitle, base: folderTitle) {
            ep.series = fileTitle
        } else if !folderTitle.isEmpty {
            ep.series = folderTitle
        } else if ep.series.isEmpty {
            ep.series = "Unknown"
        }
        ep.year = ep.year ?? folder?.year
        ep.providerTag = providerTag
        return ep
    }

    /// Whether `title` is a STRICT word-extension of `base` by a GENUINE sub-show
    /// name — `base` is a proper word-prefix AND the added words include a real name
    /// word (alphabetic, not a year / season marker / release tag). "The Witcher
    /// Blood Origin" extends "The Witcher" (adds "Blood Origin"), but "American
    /// Pickers 2022" or a broken "American Pickers S2022E" does NOT (the extra is a
    /// year / date-episode token) — those are date organisation of the SAME show and
    /// must fold into the parent. Case/punctuation-insensitive.
    static func titleStrictlyExtends(_ title: String, base: String) -> Bool {
        let a = seriesMatchKey(title)
        let b = seriesMatchKey(base)
        guard !b.isEmpty, a != b, a.hasPrefix(b + " ") else { return false }
        let suffix = String(a.dropFirst(b.count + 1))
        return suffix.split(separator: " ").map(String.init).contains { token in
            token.count >= 2
                && token.allSatisfy { $0.isLetter }
                && !isYearToken(token)
                && !isSeasonToken(token)
                && !seriesTitleStopTokens.contains(token)
        }
    }

    /// Lowercased, alphanumerics-only, single-space title key for prefix comparison.
    private static func seriesMatchKey(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Whether a genuine nested sub-show container sits DIRECTLY below the show
    /// folder — the structural mark of a spinoff (`The Witcher/Blood Origin/…`) as
    /// opposed to a season/release layout (`Show/Season 1/Show (2020) S01 (…)/…`).
    /// Requiring the IMMEDIATE child (not any descendant) to be the non-season,
    /// non-library folder is what separates a real spinoff — which sits right under
    /// the show — from a redundant release folder nested under a `Season N` folder
    /// (whose stray filename variant like "Your Honor US.S01E10" must NOT fork a
    /// separate series).
    static func nestedSubShowPresent(ancestors: [String], showFolder: String?) -> Bool {
        guard let showFolder, let idx = ancestors.firstIndex(of: showFolder), idx + 1 < ancestors.count else {
            return false
        }
        let child = ancestors[idx + 1]
        return !isSeasonFolder(child) && !isLibraryRootName(child)
    }

    /// Whether a folder component names a known library root (series OR movie),
    /// so it is never mistaken for a show/season/movie title.
    static func isLibraryRootName(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        return seriesLibraryNames.contains(n) || movieLibraryNames.contains(n)
    }

    /// The folder that AUTHORITATIVELY names the series — preferred over the
    /// filename — but only when the folder tree *proves* it is a show folder, so a
    /// junk container (`Downloads/Breaking Bad S01E01.mkv`) never overrides a good
    /// filename. Two proofs, in order:
    ///  1. A `Season N` ancestor exists → the show folder is the nearest non-season
    ///     ancestor ABOVE the outermost season folder. This hops over a redundant
    ///     nested subfolder below the season (e.g. `Show/Season 1/Show S01/…`) and
    ///     over stacked season-ish folders.
    ///  2. Otherwise, a recognized library root (`TV`, `Anime`, …) exists → the
    ///     show folder is the ancestor immediately below it.
    /// Returns nil when neither proof holds, leaving the filename as the series
    /// source. `ancestors` are root-first.
    static func authoritativeShowFolder(fromAncestors ancestors: [String]) -> String? {
        // (1) Directly above the outermost season folder.
        if let seasonIdx = ancestors.firstIndex(where: isSeasonFolder), seasonIdx >= 1 {
            var idx = seasonIdx - 1
            while idx > 0, isSeasonFolder(ancestors[idx]) { idx -= 1 }
            let candidate = ancestors[idx]
            if !isSeasonFolder(candidate), !isLibraryRootName(candidate) {
                return candidate
            }
        }
        // (2) Directly below a recognized library root.
        if let rootIdx = ancestors.firstIndex(where: isLibraryRootName),
           rootIdx + 1 < ancestors.count {
            let candidate = ancestors[rootIdx + 1]
            if !isSeasonFolder(candidate), !isLibraryRootName(candidate) {
                return candidate
            }
        }
        return nil
    }

    enum Kind: Equatable {
        case movie(Movie)
        case episode(Episode)
    }

    /// The series title carried by the FILENAME alone (folder tree ignored), used
    /// at enrichment to recover a richer search title than a generic show folder
    /// gives — e.g. an "Avatar (2024)" folder whose files are named
    /// "Avatar The Last Airbender 2024 S01E01". Returns the normalized filename
    /// title (empty stripped) so the caller can offer it as an extra TVDB search
    /// candidate. Nil when the filename carries no usable title.
    static func filenameSeriesTitle(relPath: String) -> String? {
        let comps = relPath.split(separator: "/").map(String.init)
        guard let fileName = comps.last else { return nil }
        let stem = (fileName as NSString).deletingPathExtension
        let series: String
        if let ep = parseEpisode(stem: stem, parentFolder: nil) {
            series = ep.series
        } else if let ep = parseBareEpisode(stem: stem, seasonFolder: nil, showFolder: nil) {
            series = ep.series
        } else {
            return nil
        }
        let trimmed = series.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Folder context

    /// What a folder in the path tells us about the library it belongs to.
    enum PathContext: Equatable { case seriesLibrary, movieLibrary, unknown }

    /// Library-root folder names that mark their subtree as **series** content.
    /// Matched as a whole component (so `Anime` ⇒ series but `Anime Movies` ⇒
    /// movie — see `movieLibraryNames`).
    private static let seriesLibraryNames: Set<String> = [
        "tv", "tvshows", "tv shows", "tv-shows", "shows", "series", "tv series",
        "anime", "animes", "anime tv", "anime series", "cartoons",
    ]

    /// Library-root folder names that mark their subtree as **movie** content.
    /// Includes the anime-film variants so anime *movies* aren't misread as series.
    private static let movieLibraryNames: Set<String> = [
        "movies", "movie", "films", "film", "cinema", "4k movies", "uhd movies",
        "anime movies", "anime films", "anime movie",
    ]

    /// The library context implied by the path: the FIRST (top-most) ancestor that
    /// names a known library root decides, so `Movies/Star Wars (1977)` is a movie
    /// library and `Anime/Show` is a series library. `.unknown` when no ancestor
    /// names a recognised root (the classifier then falls back to filename rules).
    static func libraryContext(_ ancestors: [String]) -> PathContext {
        for folder in ancestors {
            let name = folder.lowercased().trimmingCharacters(in: .whitespaces)
            if movieLibraryNames.contains(name) { return .movieLibrary }
            if seriesLibraryNames.contains(name) { return .seriesLibrary }
        }
        return .unknown
    }

    private static func yearBearingMovieFolder(_ folder: String, containsTitleNumber number: Int) -> Bool {
        guard let parsed = movieFolderIdentity(folder) else { return false }
        return title(parsed.title, containsStandaloneNumber: number)
    }

    private static func title(_ title: String, containsStandaloneNumber number: Int) -> Bool {
        title.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
            .contains(number)
    }

    /// A dedicated `Title (Year)` folder. A bare year bucket (`Movies/2024/`) is
    /// NOT a movie identity — it contains unrelated titles and must not collapse
    /// them into versions of a movie called "2024".
    private static func movieFolderIdentity(_ folder: String) -> Movie? {
        let ns = folder as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = yearPattern.matches(in: folder, range: full).last,
              let year = Int(ns.substring(with: match.range)) else { return nil }
        let title = clean(ns.substring(to: match.range.location))
        guard !title.isEmpty,
              title.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
        return Movie(title: title, year: year)
    }

    // MARK: - Episode

    static func parseEpisode(stem: String, parentFolder: String?) -> Episode? {
        let ns = stem as NSString
        let full = NSRange(location: 0, length: ns.length)
        for regex in episodePatterns {
            guard let m = regex.firstMatch(in: stem, range: full), m.numberOfRanges >= 3,
                  let season = Int(ns.substring(with: m.range(at: 1))),
                  let episode = Int(ns.substring(with: m.range(at: 2))) else { continue }

            // Series name = the text before the marker, normalized (junk/year
            // stripped). Empty (file is just "S01E02") → the caller resolves the
            // series from the folder tree.
            let before = ns.substring(to: m.range.location)
            let normalized = normalizeSeriesTitleAndYear(before)
            let series = normalized.title

            // Episode title = whatever trails the marker, cleaned (often junk /
            // release tags — kept only if it looks like words, not a scene tag).
            let afterStart = m.range.location + m.range.length
            let after = afterStart < ns.length ? ns.substring(from: afterStart) : ""
            let title = episodeTitle(from: after)

            return Episode(series: series, season: season, episode: episode,
                           title: title, year: normalized.year)
        }
        return nil
    }

    // MARK: - Bare episode numbers (only trusted in a TV/anime folder context)

    /// Parse an episode whose filename carries only a **bare number** — the common
    /// anime / loosely-named-TV case the strict `SxxEyy` patterns reject
    /// (`Sword Art Online II - 18.mkv`, `Show E18.mkv`, `Show #18.mkv`,
    /// `Show 18.mkv`). Only called by ``classify(relPath:)`` once the folder tree
    /// has established a TV context, so a movie whose title ends in a number
    /// (`Rocky 2`, `Ocean's 11`) can't reach here from a `Movies/` folder.
    ///
    /// The season comes from a `Season N`/`Specials` ancestor when present, else
    /// defaults to 1 (absolute-numbered anime with no season folder is treated as
    /// season 1 — matching the catalog's `COALESCE(season,1)`).
    static func parseBareEpisode(stem: String, seasonFolder: String?, showFolder: String?) -> Episode? {
        guard let (episode, before) = bareEpisodeNumber(fromStem: stem) else { return nil }
        let season = seasonFolder.flatMap(seasonNumber(fromFolder:)) ?? 1
        let normalized = normalizeSeriesTitleAndYear(before)
        return Episode(series: normalized.title, season: season, episode: episode,
                       title: nil, year: normalized.year)
    }

    /// Extracts a bare episode number and the series text that precedes it. Tries,
    /// right-most first: an explicit `E18`/`Ep 18`/`#18`/`[18]` token, else the
    /// last standalone integer in the (lightly de-tagged) stem. Returns `nil` when
    /// no plausible number remains — so a title that is only words stays a movie.
    static func bareEpisodeNumber(fromStem stem: String) -> (episode: Int, before: String)? {
        // Numeric square brackets are a common anime absolute-number convention
        // (`Show [18]`). Extract them before removing bracketed release tags.
        let originalNS = stem as NSString
        let originalRange = NSRange(location: 0, length: originalNS.length)
        if let bracketed = try? NSRegularExpression(pattern: #"\[(\d{1,3})\]"#),
           let match = bracketed.matches(in: stem, range: originalRange).last,
           let number = Int(originalNS.substring(with: match.range(at: 1))),
           number > 0 {
            return (number, originalNS.substring(to: match.range.location))
        }

        // Strip bracket groups and resolution/quality tokens first, so a `1080p` /
        // `[Group]` / `(2016)` can't be mistaken for the episode number. Preserve
        // offsets is unnecessary — we only need the surviving text + its own layout.
        var s = stem
        s = s.replacingOccurrences(of: #"[\[\(\{][^\]\)\}]*[\]\)\}]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b\d{3,4}\s*[xX]\s*\d{3,4}\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b\d{3,4}[piPI]\b"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\b(?:x26[45]|hevc|h ?26[45]|web[- ]?dl|webrip|bluray|hdtv|remux|aac|ddp?5? ?1?|4k|uhd|hdr|dv)\b"#,
                                    with: " ", options: .regularExpression)
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Explicit episode tokens (highest confidence), right-most wins.
        for pattern in [#"(?i)\bep(?:isode)?[\s._-]*(\d{1,4})"#, #"(?i)\be(\d{1,4})\b"#, #"#(\d{1,4})"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if let m = regex.matches(in: s, range: full).last, m.numberOfRanges >= 2,
               let n = Int(ns.substring(with: m.range(at: 1))), n > 0, n < 10_000 {
                return (n, ns.substring(to: m.range.location))
            }
        }

        // Otherwise the last standalone integer — the anime `Show - 18` / `Show 18`
        // case. `before` is everything up to that number (the series text).
        guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9])(\d{1,4})(?![0-9])"#),
              let m = regex.matches(in: s, range: full).last,
              let n = Int(ns.substring(with: m.range(at: 1))), n > 0, n < 10_000 else { return nil }
        return (n, ns.substring(to: m.range.location))
    }

    /// The season number encoded by a season-folder name: `Season 3`/`S03` → 3,
    /// `Staffel 2` → 2, `Specials` → 0. `nil` when the folder isn't a season.
    static func seasonNumber(fromFolder folder: String?) -> Int? {
        guard let folder else { return nil }
        let l = folder.lowercased().trimmingCharacters(in: .whitespaces)
        if l == "specials" || l == "special" { return 0 }
        let ns = l as NSString
        let full = NSRange(location: 0, length: ns.length)
        for pattern in [#"^(?:season|staffel|series)\s*0*(\d{1,3})$"#, #"^s0*(\d{1,3})$"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if let m = regex.firstMatch(in: l, range: full), m.numberOfRanges >= 2 {
                return Int(ns.substring(with: m.range(at: 1)))
            }
        }
        return nil
    }

    /// Whether a folder name is a season container (`Season 3`, `S03`,
    /// `Staffel 2`, `Series 4`, `Specials`) rather than a show or a movie.
    static func isSeasonFolder(_ name: String) -> Bool {
        seasonNumber(fromFolder: name) != nil
    }

    /// The folder that best names a *series* for an episode file, given the file's
    /// ancestor folders (root-first): normally the immediate parent, but hop over a
    /// `Season N`/`Specials` folder to the show above it.
    static func seriesHintFolder(fromAncestors ancestors: [String]) -> String? {
        guard let parent = ancestors.last else { return nil }
        if isSeasonFolder(parent), ancestors.count >= 2 {
            return ancestors[ancestors.count - 2]
        }
        return parent
    }

    private static func episodeTitle(from raw: String) -> String? {
        let cleaned = clean(raw)
        guard !cleaned.isEmpty else { return nil }
        // Release names put the real episode title first, then scene/quality tags
        // ("Pilot 720p WEB-DL x264", "The Body HDR 2160p WEB h265-EDITH"). Keep
        // words up to the first tag so we show "Pilot", not "Pilot 720p" — and so
        // a title-less "S01E06.HDR..." doesn't become an episode called "HDR".
        // Reuse the series stop-token set (quality/codec/HDR/audio/network/edition)
        // plus resolution tokens. Require at least one real (non-numeric) word.
        let extraTags: Set<String> = ["1080p", "720p", "2160p", "480p", "4k"]
        var kept: [String] = []
        for word in cleaned.split(separator: " ").map(String.init) {
            // Match hyphen-insensitively so tight scene spellings like "WEB-DL"
            // (which `clean` leaves intact — it only splits space-flanked dashes)
            // still cut the title, not just the space-separated forms.
            let lower = word.lowercased()
            let dehyphenated = lower.replacingOccurrences(of: "-", with: "")
            if extraTags.contains(lower)
                || seriesTitleStopTokens.contains(lower)
                || seriesTitleStopTokens.contains(dehyphenated) { break }
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

    /// The `(title, year)` a movie file should GROUP by, plus a stacked-part token.
    /// Uses the dedicated movie folder (`Movies/Star Wars (1977)/…`) as the identity
    /// when present — the way Plex/Jellyfin fold several files in one movie folder
    /// into one title — so differently-named quality/edition files still collapse to
    /// one logical movie. Loose files (`Movies/Star Wars (1977).mkv`) fall back to
    /// the filename's parsed title+year. A stacked part (`CD1`/`Part2`) is returned
    /// separately so the caller can keep parts as distinct entries rather than
    /// mis-presenting them as selectable versions of one playable title.
    static func movieGrouping(relPath: String, parsedTitle: String, parsedYear: Int?) -> (title: String, year: Int?, part: String?) {
        let comps = relPath.split(separator: "/").map(String.init)
        let fileName = comps.last ?? relPath
        let ancestors = Array(comps.dropLast())

        var title = parsedTitle
        var year = parsedYear
        // A dedicated `Title (Year)` movie folder is a strong identity: require the
        // folder name to carry a year and not be a library root / season folder.
        if let parent = ancestors.last {
            let name = parent.lowercased().trimmingCharacters(in: .whitespaces)
            let isRoot = seriesLibraryNames.contains(name) || movieLibraryNames.contains(name)
            if !isRoot, !isSeasonFolder(parent), let folder = movieFolderIdentity(parent) {
                title = folder.title
                year = folder.year
            }
        }
        return (title, year, stackedPartToken(fileName: fileName))
    }

    /// A multi-file movie's part marker (`CD1`, `Part 2`, `Disc1`, `pt2`) as a
    /// normalized token, or `nil` when the file isn't a stacked part. Used to keep
    /// the parts of one split movie as separate catalog entries (we can't play a
    /// concatenated multi-part stream yet) rather than collapsing them into one
    /// title whose "versions" would each be an incomplete half.
    static func stackedPartToken(fileName: String) -> String? {
        let stem = (fileName as NSString).deletingPathExtension.lowercased()
        let ns = stem as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: #"\b(cd|dvd|disc|disk|part|pt)\s*0*(\d{1,2})\b"#),
              let m = regex.firstMatch(in: stem, range: full), m.numberOfRanges >= 3,
              let n = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        let word = ns.substring(with: m.range(at: 1))
        return "\(word)\(n)"
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

    // MARK: - Series title normalization

    /// Tokens that TERMINATE a series title: from the first such token on, the text
    /// is a caption marker or a technical source/quality/codec/audio tag — not part
    /// of the show name. DELIBERATELY CONSERVATIVE: only tokens that are essentially
    /// never real title words are listed, so a legitimate title is never truncated
    /// (e.g. "The Collection", "Mad Max", "Charlotte's Web" survive). Ambiguous
    /// English words and streaming-network abbreviations (collection, complete, max,
    /// web, dual, dolby, opus, hulu, stan, itv, …) are intentionally EXCLUDED —
    /// season/year boundaries (handled separately) already cut the real junk before
    /// them. `remix` is kept only because a real variant folder needed it.
    /// (Matched only AFTER at least one title token is kept.)
    private static let seriesTitleStopTokens: Set<String> = [
        // Caption / subtitle markers (rarely a title word)
        "cc", "sdh",
        // Variant marker seen in real folders (Arrested Development Remix)
        "remix",
        // Source / quality (not English words)
        "bluray", "brrip", "bdrip", "webrip", "webdl", "hdtv", "dvdrip",
        "dvdscr", "hdrip", "remux",
        // Codecs / bit depth
        "x264", "x265", "h264", "h265", "hevc", "xvid", "divx", "10bit", "8bit",
        // Dynamic range
        "hdr", "hdr10", "sdr", "dv", "dovi", "hlg",
        // Audio (not English words)
        "aac", "ac3", "eac3", "ddp", "dts", "truehd", "atmos", "flac",
    ]

    /// Season-marker tokens that also terminate a title (`Season`, `Staffel`,
    /// `S01`, `S1`) so a folder like "House of the Dragon Season 1 S01" or a
    /// filename prefix "Show 2024 S01" collapses to the show name.
    private static func isSeasonToken(_ lower: String) -> Bool {
        if lower == "season" || lower == "staffel" { return true }
        return lower.range(of: #"^s\d{1,2}$"#, options: .regularExpression) != nil
    }

    private static func isYearToken(_ lower: String) -> Bool {
        lower.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil
    }

    /// The last 4-digit year in `raw`, or nil. Bracketed `[tmdb-2019]`/`{...}`
    /// provider tags are stripped FIRST so an id's digits can't be misread as the
    /// year ("Show (1990) [tmdb-2019]" → 1990, not 2019). Resolution-like numbers
    /// are excluded via the shared `yearPattern`.
    static func extractYear(_ raw: String) -> Int? {
        let deTagged = raw
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: " ", options: .regularExpression)
        let ns = deTagged as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = yearPattern.matches(in: deTagged, range: full).last else { return nil }
        return Int(ns.substring(with: match.range))
    }

    /// Normalizes a raw title fragment (a filename prefix or a folder name) into a
    /// clean SERIES title plus any recovered year. The title is cut at the first
    /// junk token (year / season marker / quality-edition tag), so
    /// "The Last of Us (2023) - Season 01 - LVL7T7" → ("The Last of Us", 2023),
    /// "Deadloch.cc" → ("Deadloch", nil), "Avatar The Last Airbender 2024" →
    /// ("Avatar The Last Airbender", 2024), "Arrested Development Remix" →
    /// ("Arrested Development", nil). The first token is always kept, so a title
    /// that IS a year ("1883") or collides with a tag word ("Max Headroom")
    /// survives. Empty title in → empty out (caller falls back to another source).
    static func normalizeSeriesTitleAndYear(_ raw: String) -> (title: String, year: Int?) {
        let year = extractYear(raw)
        let cleaned = clean(raw)
        guard !cleaned.isEmpty else { return ("", year) }
        var kept: [String] = []
        for word in cleaned.split(separator: " ").map(String.init) {
            if !kept.isEmpty {
                let lw = word.lowercased()
                if isYearToken(lw) || isSeasonToken(lw) || seriesTitleStopTokens.contains(lw) {
                    break
                }
            }
            kept.append(word)
        }
        return (kept.joined(separator: " ").trimmingCharacters(in: .whitespaces), year)
    }

    /// Convenience: just the normalized title.
    static func normalizeSeriesTitle(_ raw: String) -> String {
        normalizeSeriesTitleAndYear(raw).title
    }
}
