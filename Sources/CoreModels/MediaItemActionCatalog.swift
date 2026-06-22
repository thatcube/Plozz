import Foundation

/// Extra, screen-supplied context that lets the context menu offer list-aware
/// actions. Most screens supply nothing (`.none`); a series/season episode list
/// supplies the ordering so "mark watched up to here" knows what "up to here"
/// means.
public struct MediaItemActionContext: Sendable, Equatable {
    /// The items in the same list as the target, in display order — a season's
    /// episodes, sorted by episode number. Empty where the surrounding screen
    /// doesn't know an ordering (e.g. a Home rail of unrelated items).
    public var orderedSiblings: [MediaItem]

    /// Container ids (earlier seasons) that "mark watched up to here" should mark
    /// fully watched in addition to the preceding `orderedSiblings`. Lets the
    /// action span seasons: marking up to S2E3 also clears all of season 1.
    public var precedingContainerIDs: [String]

    public init(orderedSiblings: [MediaItem] = [], precedingContainerIDs: [String] = []) {
        self.orderedSiblings = orderedSiblings
        self.precedingContainerIDs = precedingContainerIDs
    }

    /// No surrounding-list context — the default for standalone cards.
    public static let none = MediaItemActionContext()
}

/// Pure, UI-independent rules for which `MediaItemAction`s an item offers and
/// which siblings a bulk action touches. Kept free of SwiftUI and providers so
/// it is fully unit-testable on Linux/CI.
public enum MediaItemActionCatalog {
    /// The ordered actions to show for `item`.
    ///
    /// - Parameters:
    ///   - item: the focused item the menu is for.
    ///   - supportsWatchState: whether the item's provider can mutate watched
    ///     state (i.e. conforms to `WatchStateProviding`). When `false` no
    ///     watched-state actions are offered.
    ///   - context: any surrounding-list context (see `MediaItemActionContext`).
    public static func actions(
        for item: MediaItem,
        supportsWatchState: Bool,
        context: MediaItemActionContext = .none
    ) -> [MediaItemAction] {
        guard supportsWatchState, isWatchStateEligible(item) else { return [] }

        var actions: [MediaItemAction] = [item.isPlayed ? .markUnwatched : .markWatched]

        // "Up to here" only makes sense for an episode whose position in its
        // list is known and where something up to that point is still unwatched.
        if item.kind == .episode, hasUnwatchedUpToHere(item, in: context) {
            actions.append(.markWatchedUpToHere)
        }
        return actions
    }

    /// The siblings "mark watched up to here" should mark watched: every sibling
    /// up to and including `item` in display order that isn't already watched.
    /// Empty when `item` isn't found in `siblings`.
    public static func siblingsToMarkUpToHere(_ item: MediaItem, in siblings: [MediaItem]) -> [MediaItem] {
        guard let index = siblings.firstIndex(where: { $0.id == item.id }) else { return [] }
        return siblings[...index].filter { !$0.isPlayed }
    }

    /// Whether `item` is a kind that can carry a watched state at all. Folders,
    /// collections and unknowns can't.
    private static func isWatchStateEligible(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie, .episode, .video, .season, .series: return true
        case .folder, .collection, .unknown: return false
        }
    }

    private static func hasUnwatchedUpToHere(_ item: MediaItem, in context: MediaItemActionContext) -> Bool {
        if !context.precedingContainerIDs.isEmpty { return true }
        return !siblingsToMarkUpToHere(item, in: context.orderedSiblings).isEmpty
    }
}
