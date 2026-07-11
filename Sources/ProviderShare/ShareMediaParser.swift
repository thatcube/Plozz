import Foundation

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
    static let classifierVersion = 7

    /// File extensions we treat as playable video.
    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts",
        "wmv", "mpg", "mpeg", "flv", "ogv", "3gp",
    ]

    static func isVideoFile(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
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
    ///
    /// Filename-only fallback kept for callers/tests without a full path; the
    /// production paths use ``classify(relPath:)``, which also weighs the folder
    /// tree — the strongest real-world signal (how Plex/Jellyfin/Infuse decide).
    static func classify(fileName: String, parentFolder: String?) -> Kind {
        let stem = (fileName as NSString).deletingPathExtension
        if let ep = parseEpisode(stem: stem, parentFolder: parentFolder) {
            return .episode(ep)
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

        // (1) Explicit episode marker — strongest, works in any folder.
        if let ep = parseEpisode(stem: stem, parentFolder: showHint) {
            return .episode(ep)
        }

        // (2) Folder says "this is a series" → accept a bare episode number.
        let seasonAncestor = ancestors.last(where: isSeasonFolder)
        let context = libraryContext(ancestors)
        if seasonAncestor != nil || context == .seriesLibrary {
            if let ep = parseBareEpisode(stem: stem, seasonFolder: seasonAncestor, showFolder: showHint) {
                if seasonAncestor == nil {
                    let fileMovie = parseMovie(stem: stem, parentFolder: nil)
                    if fileMovie.year != nil,
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
                return .episode(ep)
            }
        }

        // (3)/(4) Movie: a `Title (Year)` folder / movie library root, or the
        // filename fallback. `ancestors.last` gives the movie folder its year/title
        // when the filename lacks them (`Star Wars (1977)/movie.mkv`).
        return .movie(parseMovie(stem: stem, parentFolder: ancestors.last))
    }

    enum Kind: Equatable {
        case movie(Movie)
        case episode(Episode)
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
        var series = clean(before)
        if series.isEmpty {
            series = seriesFromFolder(showFolder) ?? "Unknown"
        }
        return Episode(series: series, season: season, episode: episode, title: nil)
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

    private static func seriesFromFolder(_ folder: String?) -> String? {
        guard let folder, !folder.isEmpty else { return nil }
        // A season folder names the season, not the show; a library-root folder
        // (`Anime`, `Movies`, `TV`) names neither — never use either as a title.
        if isSeasonFolder(folder) { return nil }
        let name = folder.lowercased().trimmingCharacters(in: .whitespaces)
        if seriesLibraryNames.contains(name) || movieLibraryNames.contains(name) { return nil }
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
}
