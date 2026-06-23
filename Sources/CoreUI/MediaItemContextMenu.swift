#if canImport(SwiftUI)
import SwiftUI
import CoreModels

// MARK: - Environment plumbing
//
// The context menu is wired through the SwiftUI environment rather than threaded
// as closures through every `MediaRowView` / `PosterCardView` call site. The app
// installs one handler at the root (`.mediaItemActionHandler(_:)`); list screens
// that know an ordering (a season's episodes) additionally supply context with
// `.mediaItemActionContext(_:)`. Cards read both and render a native menu.

private struct MediaItemActionHandlerKey: EnvironmentKey {
    static let defaultValue: (any MediaItemActionHandling)? = nil
}

private struct MediaItemActionContextKey: EnvironmentKey {
    static let defaultValue: MediaItemActionContext = .none
}

private struct MediaItemNavigatorKey: EnvironmentKey {
    static let defaultValue: ((MediaItem) -> Void)? = nil
}

public extension EnvironmentValues {
    /// The app-supplied handler that builds and performs context-menu actions.
    /// `nil` (the default) disables the menu — e.g. in previews and tests.
    var mediaItemActionHandler: (any MediaItemActionHandling)? {
        get { self[MediaItemActionHandlerKey.self] }
        set { self[MediaItemActionHandlerKey.self] = newValue }
    }

    /// Surrounding-list context for the current subtree (e.g. a season's
    /// episodes in order), enabling list-aware actions like "watched up to here".
    var mediaItemActionContext: MediaItemActionContext {
        get { self[MediaItemActionContextKey.self] }
        set { self[MediaItemActionContextKey.self] = newValue }
    }

    /// The view-layer router used by navigation context-menu actions (e.g. "Go
    /// to Season") to push a destination. Each navigation stack installs one that
    /// appends to its own path. `nil` disables navigation actions.
    var mediaItemNavigator: ((MediaItem) -> Void)? {
        get { self[MediaItemNavigatorKey.self] }
        set { self[MediaItemNavigatorKey.self] = newValue }
    }
}

public extension View {
    /// Installs the context-menu action handler for every card in this subtree.
    func mediaItemActionHandler(_ handler: (any MediaItemActionHandling)?) -> some View {
        environment(\.mediaItemActionHandler, handler)
    }

    /// Supplies ordered-list context so cards in this subtree can offer
    /// list-aware actions (e.g. "mark watched up to here" for a season's rail).
    func mediaItemActionContext(_ context: MediaItemActionContext) -> some View {
        environment(\.mediaItemActionContext, context)
    }

    /// Installs the router that navigation context-menu actions (e.g. "Go to
    /// Season") use to push a destination for this subtree's navigation stack.
    func mediaItemNavigator(_ navigate: ((MediaItem) -> Void)?) -> some View {
        environment(\.mediaItemNavigator, navigate)
    }

    /// Attaches the native tvOS press-and-hold menu for `item`, populated from
    /// the environment's action handler. A no-op when no handler is installed or
    /// the item has no available actions.
    func mediaItemContextMenu(for item: MediaItem) -> some View {
        modifier(MediaItemContextMenu(item: item))
    }
}

// MARK: - The menu

/// Renders the native tvOS context menu (long-press on the focused card) for a
/// `MediaItem`, driven entirely by the injected `MediaItemActionHandling`.
public struct MediaItemContextMenu: ViewModifier {
    private let item: MediaItem
    @Environment(\.mediaItemActionHandler) private var handler
    @Environment(\.mediaItemActionContext) private var context
    @Environment(\.mediaItemNavigator) private var navigator

    public init(item: MediaItem) {
        self.item = item
    }

    public func body(content: Content) -> some View {
        let actions = availableActions()
        if !actions.isEmpty {
            content.contextMenu {
                ForEach(actions) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        perform(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            }
        } else {
            content
        }
    }

    /// The actions to render, dropping navigation actions when no router is
    /// installed (so they never appear as dead buttons).
    private func availableActions() -> [MediaItemAction] {
        let actions = handler?.actions(for: item, context: context) ?? []
        return actions.filter { !$0.isNavigation || navigator != nil }
    }

    private func perform(_ action: MediaItemAction) {
        if action.isNavigation {
            navigate(action)
        } else {
            handler?.perform(action, on: item, context: context)
        }
    }

    /// Routes a navigation action through the environment's router. Navigation
    /// builds a lightweight destination item from what the card already knows;
    /// the destination screen re-fetches full detail by id.
    private func navigate(_ action: MediaItemAction) {
        switch action {
        case .goToSeason:
            guard let target = item.seasonNavigationTarget else { return }
            navigator?(target)
        case .goToMovie:
            navigator?(item)
        case .markWatched, .markUnwatched, .markWatchedUpToHere:
            break
        }
    }
}

private extension MediaItem {
    /// The destination for "Go to Season". Preferred: the full **series** detail
    /// page (rich hero, badges, season tabs, episode rail) with this episode's
    /// season pre-selected, carried in `seasonID`. Falls back to a bare season
    /// page only when the series id is unknown. The destination screen reloads
    /// full data by `id`, so only `id`, `kind`, the season hint and the owning
    /// account need to be accurate here.
    var seasonNavigationTarget: MediaItem? {
        if let seriesID {
            return MediaItem(
                id: seriesID,
                title: parentTitle ?? "Series",
                kind: .series,
                seasonID: seasonID,
                sourceAccountID: sourceAccountID
            )
        }
        guard let seasonID else { return nil }
        let title = seasonNumber.map { "Season \($0)" } ?? "Season"
        return MediaItem(
            id: seasonID,
            title: title,
            kind: .season,
            parentTitle: parentTitle,
            seasonNumber: seasonNumber,
            sourceAccountID: sourceAccountID
        )
    }
}

#endif
