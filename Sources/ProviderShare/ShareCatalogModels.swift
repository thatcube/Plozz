import Foundation

/// Value types + id scheme for the persistent share catalog (the SQLite-backed
/// index a `ShareScanner` builds by walking the share once, so Home / Search can
/// answer instantly without a live SMB round-trip).
///
/// **Id scheme (kept compatible with the raw browser + playback/watch plumbing):**
///   * a playable leaf (movie or episode) → `"f:<relpath>"` — the SAME id the raw
///     `ShareLibraryStore` uses, so `ShareProvider.playbackInfo` / `ShareWatchStore`
///     keys keep working unchanged (both derive the file from the `f:` prefix).
///   * a logical series → `"series:<seriesKey>"` (a synthetic container).
///   * a season → `"season:<seriesKey>:<n>"`.
///   * the synthetic indexed libraries → `share:lib:movies|tv|anime`.
/// The raw file-tree library (`ShareLibraryStore.rootLibraryID` == `share:root`,
/// `d:<relpath>` folders) is untouched and remains the truth-preserving fallback.

/// Which indexed library an asset belongs to. `.tv` and `.anime` both hold
/// `.series`; anime is split out because the app classifies + fetches anime
/// metadata separately. Classification is best-effort at scan time (folder hint)
/// and confirmed later once real ids resolve (Phase 2).
enum CatalogLibrary: String, Sendable, CaseIterable {
    case movies
    case tv
    case anime
}

/// What a playable file parsed to.
enum CatalogAssetKind: String, Sendable {
    case movie
    case episode
}

/// One playable file discovered on the share, plus the metadata parsed from its
/// name/folder. Physical row in the catalog; logical series/season items are
/// derived from these by grouping on `seriesKey`.
struct CatalogAsset: Sendable, Equatable {
    var relPath: String
    var basename: String
    var size: Int64
    var modifiedAt: Date
    var kind: CatalogAssetKind
    var library: CatalogLibrary
    /// Movie title, or episode title (falls back to `S·E` when the name carried none).
    var title: String
    var year: Int?
    // Episode-only:
    var seriesTitle: String?
    var seriesKey: String?
    var season: Int?
    var episode: Int?
    /// Movie-only: the stable grouping key that collapses several files of the SAME
    /// film (a 4K remux beside a 1080p web-dl, or an edition variant) into one
    /// logical movie with selectable versions — the share's local equivalent of the
    /// server-side version grouping Plex/Jellyfin do. Derived from the movie folder
    /// (`Title (Year)/`) when present, else the parsed title+year; stacked parts
    /// (`CD1`/`CD2`) get distinct keys so they aren't mis-presented as versions.
    /// `nil` for episodes and for movie rows indexed before this column existed
    /// (they group as singletons until the next reparse). Never rewritten by
    /// enrichment, so `movie:<key>` ids stay stable for watch-state / TopShelf.
    var movieKey: String?
    /// Year-independent normalized title key used to discover near-year variants.
    /// Stacked parts append their part token so CD1/CD2 never become versions.
    var movieTitleKey: String?
}

/// Central id scheme for catalog items so the store, scanner, and provider agree.
enum ShareCatalogID {
    static let moviesLibrary = "share:lib:movies"
    static let tvLibrary = "share:lib:tv"
    static let animeLibrary = "share:lib:anime"

    static func library(_ lib: CatalogLibrary) -> String {
        switch lib {
        case .movies: return moviesLibrary
        case .tv: return tvLibrary
        case .anime: return animeLibrary
        }
    }

    static func catalogLibrary(forID id: String) -> CatalogLibrary? {
        switch id {
        case moviesLibrary: return .movies
        case tvLibrary: return .tv
        case animeLibrary: return .anime
        default: return nil
        }
    }

    /// Playable leaf id — identical to the raw browser's `f:` scheme so playback
    /// and watch-state keys are shared.
    static func file(_ relPath: String) -> String { "f:\(relPath)" }
    static func relPath(forFileID id: String) -> String? {
        id.hasPrefix("f:") ? String(id.dropFirst(2)) : nil
    }

    static func series(_ key: String) -> String { "series:\(key)" }
    static func isSeries(_ id: String) -> Bool { id.hasPrefix("series:") }
    static func seriesKey(forSeriesID id: String) -> String? {
        id.hasPrefix("series:") ? String(id.dropFirst("series:".count)) : nil
    }

    /// A logical movie container id (`movie:<key>`) whose selectable versions are
    /// the individual files that share the key. Mirrors the `series:<key>` scheme.
    static func movie(_ key: String) -> String { "movie:\(key)" }
    static func isMovie(_ id: String) -> Bool { id.hasPrefix("movie:") }
    static func movieKey(forMovieID id: String) -> String? {
        id.hasPrefix("movie:") ? String(id.dropFirst("movie:".count)) : nil
    }

    /// Stable, filesystem/id-safe grouping key for a movie: the normalized title
    /// plus its year, so two files of the SAME film collapse to one logical movie
    /// while a same-title different-year film stays distinct. Never contains a
    /// colon. Deterministic and independent of enrichment (see `CatalogAsset`).
    static func movieKey(fromTitle title: String, year: Int?) -> String {
        let base = seriesKey(fromTitle: title)
        let stem = base.isEmpty ? "untitled" : base
        if let year { return "\(stem)-\(year)" }
        return stem
    }

    static func season(_ key: String, _ season: Int) -> String { "season:\(key):\(season)" }
    static func isSeason(_ id: String) -> Bool { id.hasPrefix("season:") }
    /// Decode a `season:<key>:<n>` id back into `(seriesKey, seasonNumber)`.
    /// The season number is the trailing `:<int>`; everything between the
    /// `season:` prefix and that is the (possibly `:`-containing) series key.
    static func seasonComponents(forSeasonID id: String) -> (seriesKey: String, season: Int)? {
        guard id.hasPrefix("season:") else { return nil }
        let body = String(id.dropFirst("season:".count))
        guard let sep = body.lastIndex(of: ":") else { return nil }
        let key = String(body[body.startIndex..<sep])
        let seasonStr = String(body[body.index(after: sep)...])
        guard let season = Int(seasonStr), !key.isEmpty else { return nil }
        return (key, season)
    }

    /// Stable, filesystem/id-safe grouping key for a series title (case- and
    /// punctuation-insensitive) so "Breaking Bad" / "breaking.bad" collapse to one
    /// series. Never contains a colon (so `seasonComponents` can split safely).
    static func seriesKey(fromTitle title: String) -> String {
        let lower = title.lowercased()
        let mapped = lower.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(mapped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
