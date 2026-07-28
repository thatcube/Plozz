#if canImport(SwiftUI)
import SwiftUI
import CoreModels

public extension MediaLibrary {
    /// The library's name, ready to render.
    ///
    /// `title` is normally a server-supplied name and must not be translated —
    /// but not always. A file share has no library list, so Plozz derives
    /// "Movies"/"TV Shows"/"Anime" itself, and Plex and Jellyfin fall back to a
    /// generic name when a section has none. Those are Plozz's own words, and
    /// rendering them from `title` left them permanently English.
    ///
    /// One accessor rather than the choice being made at each of the ~10 places
    /// a library name is drawn: the distinction is invisible at the call site,
    /// so anywhere that reached for `title` directly would silently be wrong for
    /// share users.
    var displayName: Text {
        guard let synthesizedName else { return Text(verbatim: title) }
        return Text(synthesizedName.title)
    }
}
#endif
