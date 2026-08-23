import CoreModels
import Foundation

/// The part of ``HeroSettings`` that decides *what the hero contains* — as
/// opposed to how it presents it.
///
/// This is the line between "the world moved" and "the viewer changed their
/// mind", and both shells need to draw it in exactly the same place. Content
/// moving is routine and constant, and an already-curated hero stays on screen
/// through it while the next curation folds in (see ``HeroLiveMerge``). A change
/// to one of these values is a direct instruction, so what is showing is retired
/// at once and the fresh curation starts clean.
///
/// Deliberately excludes auto-advance, trailers and every other presentation
/// setting: flipping those must not disturb the carousel's contents.
public struct HeroConfigurationKey: Hashable, Sendable {
    public var sources: [HeroSourceKind]
    public var maxItems: Int
    public var hideWatched: Bool
    /// The libraries the viewer restricted the Random source to. Empty means "all
    /// currently-visible libraries". Included because narrowing it is a request
    /// for different titles — unlike the *resolved* library list, which changes
    /// whenever a server finishes loading and must not retire anything.
    public var randomLibraryKeys: Set<String>

    public init(settings: HeroSettings?) {
        guard let settings, settings.isActive else {
            self.sources = []
            self.maxItems = 0
            self.hideWatched = false
            self.randomLibraryKeys = []
            return
        }
        self.sources = settings.sources
        self.maxItems = settings.maxItems
        self.hideWatched = settings.hideWatched
        self.randomLibraryKeys = settings.isEnabled(.randomFromLibrary)
            ? settings.randomLibraryKeys
            : []
    }
}
