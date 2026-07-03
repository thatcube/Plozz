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

    // SxxEyy / SxxExyy, 1x02, and "Season 1 Episode 2" style markers.
    private static let episodePatterns: [NSRegularExpression] = {
        let raw = [
            #"[sS](\d{1,2})[\s._-]*[eE](\d{1,3})"#,
            #"(\d{1,2})x(\d{1,3})"#,
            #"[sS]eason[\s._-]*(\d{1,2})[\s._-]*[eE]pisode[\s._-]*(\d{1,3})"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let yearPattern = try! NSRegularExpression(pattern: #"(19|20)\d{2}"#)

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
        // Drop pure resolution/scene noise so we don't show "1080p Web Dl" as a
        // title. Require at least one word with 2+ letters that isn't a tag.
        let tags: Set<String> = [
            "1080p", "720p", "2160p", "480p", "4k", "web", "webdl", "web dl",
            "bluray", "hdtv", "x264", "x265", "hevc", "aac", "ddp", "dd", "amzn",
            "nf", "dsnp", "hmax", "atvp", "repack", "proper", "internal",
        ]
        let words = cleaned.lowercased().split(separator: " ").map(String.init)
        let meaningful = words.filter { $0.count >= 2 && !tags.contains($0) && Int($0) == nil }
        return meaningful.count >= 1 ? cleaned : nil
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
        // Common separators to spaces.
        s = s.replacingOccurrences(of: ".", with: " ")
             .replacingOccurrences(of: "_", with: " ")
        // A dash flanked by spaces is a separator; keep hyphenated words intact.
        s = s.replacingOccurrences(of: " - ", with: " ")
        // Collapse whitespace.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    }
}
