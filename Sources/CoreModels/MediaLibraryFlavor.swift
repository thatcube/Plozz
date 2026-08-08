import Foundation

/// The content flavour a library holds, resolved once so every surface that draws a
/// library (the navigation rail, the Settings arrangement list, future library
/// chrome) picks the SAME glyph for the same library.
///
/// Deliberately a small, closed enum rather than a raw SF Symbol string: the icon
/// set is a design decision that belongs in one place, and a caller that needs a
/// different presentation (a colour, a placeholder poster) can switch on the
/// flavour instead of string-matching a symbol name.
public enum MediaLibraryFlavor: String, Sendable, Hashable, CaseIterable {
    case movies
    case tvShows
    case anime
    case music
    case photos
    case mixed

    /// The SF Symbol drawn for this flavour.
    public var symbolName: String {
        switch self {
        case .movies: return "film.stack"
        case .tvShows: return "tv"
        case .anime: return "sparkles.tv"
        case .music: return "music.note"
        case .photos: return "photo.on.rectangle.angled"
        case .mixed: return "square.grid.2x2"
        }
    }
}

public extension MediaLibrary {
    /// This library's content flavour, used to pick its navigation glyph.
    ///
    /// Resolution order, most trustworthy first:
    /// 1. `synthesizedName` — Plozz derived the bucket itself (file shares), so it
    ///    already knows exactly what the library holds.
    /// 2. `isMusic` — the providers set this when mapping a Plex artist section or
    ///    a Jellyfin music collection.
    /// 3. `kind` — the server's own collection type.
    ///
    /// Anime is a special case: neither Plex nor Jellyfin has an "anime collection
    /// type", so a dedicated anime library is a *series* (or movie) library that
    /// the user named for it. Matching the name is the only signal available, and
    /// it is applied conservatively — the token has to stand alone, so "Anime" and
    /// "Anime Movies" match while a show called "Animejo" inside a normal library
    /// cannot. A false negative is harmless (a TV glyph on an anime library); a
    /// false positive would be actively wrong, hence the strict token match.
    var flavor: MediaLibraryFlavor {
        if let synthesizedName {
            switch synthesizedName {
            case .movies: return .movies
            case .tvShows: return .tvShows
            case .anime: return .anime
            case .generic: break
            }
        }
        if isMusic { return .music }
        if Self.namedForAnime(title) { return .anime }
        switch kind {
        case .movie: return .movies
        case .series, .season, .episode: return .tvShows
        case .video: return .photos
        case .folder, .collection, .unknown: return .mixed
        }
    }

    /// Whether a library's own name marks it as an anime library. Token-exact
    /// (case- and diacritic-insensitive) so only a deliberate naming matches.
    ///
    /// The Japanese form is included because a Japanese-language household names
    /// the library アニメ, and the Latin token would never match it.
    static func namedForAnime(_ title: String) -> Bool {
        let folded = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
        let tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains { $0 == "anime" || $0 == "アニメ" }
    }
}

/// The navigation glyph for a library, resolved through ``MediaLibrary/flavor``.
public extension MediaLibrary {
    var navigationSymbolName: String { flavor.symbolName }
}
