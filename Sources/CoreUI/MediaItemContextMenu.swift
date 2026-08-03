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

private struct MediaPersonNavigatorKey: EnvironmentKey {
    static let defaultValue: ((MediaPerson) -> Void)? = nil
}

private struct MediaPersonSourceNavigatorKey: EnvironmentKey {
    static let defaultValue: ((MediaPerson, String?) -> Void)? = nil
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

    /// The view-layer router used to open a person. Installed per navigation
    /// stack, exactly like ``mediaItemNavigator``. `nil` leaves cast tiles inert,
    /// which is what every surface without a stack of its own wants.
    var mediaPersonNavigator: ((MediaPerson) -> Void)? {
        get { self[MediaPersonNavigatorKey.self] }
        set { self[MediaPersonNavigatorKey.self] = newValue }
    }

    /// The same router, told WHICH server listed this person.
    ///
    /// A person id only means something to the server that issued it, and
    /// `MediaPerson` does not carry its origin — so a page that opens one has to
    /// say where it came from, or the person's own server cannot be asked for
    /// their credits at all. tvOS solves this by having each page install a
    /// navigator closed over its own account; this is the same idea expressed as
    /// one router that takes the account, so a single destination can serve every
    /// surface that pushes a person.
    var mediaPersonSourceNavigator: ((MediaPerson, String?) -> Void)? {
        get { self[MediaPersonSourceNavigatorKey.self] }
        set { self[MediaPersonSourceNavigatorKey.self] = newValue }
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

    /// Installs the router that cast tiles in this subtree use to open a person.
    func mediaPersonNavigator(_ navigate: ((MediaPerson) -> Void)?) -> some View {
        environment(\.mediaPersonNavigator, navigate)
    }

    /// See ``EnvironmentValues/mediaPersonSourceNavigator``.
    func mediaPersonSourceNavigator(
        _ navigate: ((MediaPerson, String?) -> Void)?
    ) -> some View {
        environment(\.mediaPersonSourceNavigator, navigate)
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
    /// Navigation must wait for the native context menu's rollback animation.
    /// tvOS keeps a snapshot of the lifted card alive for roughly 300 ms after an
    /// action is chosen; replacing the screen during that window orphans the poster
    /// over the destination until the system times it out. Queueing the target lets
    /// the menu dismiss first, then the task below pushes after a small safety margin.
    @State private var pendingNavigationTarget: MediaItem?

    private static var navigationDismissalDelay: Duration { .milliseconds(450) }

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
                    .accessibilityLabel(Text(action.title))
                    .accessibilityValue(
                        action.accessibilityState.map(Text.init) ?? Text(verbatim: "")
                    )
                }
            }
            .task(id: pendingNavigationTarget) {
                guard let target = pendingNavigationTarget else { return }
                do {
                    try await Task.sleep(for: Self.navigationDismissalDelay)
                } catch {
                    return
                }
                guard pendingNavigationTarget == target else { return }
                pendingNavigationTarget = nil
                navigator?(target)
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
        pendingNavigationTarget = item.navigationTarget(for: action)
    }
}

extension MediaItem {
    /// The destination a navigation action leads to, or `nil` when this item
    /// can't reach one. Shared so a hero's "…" menu and a card's long-press menu
    /// route identically.
    public func navigationTarget(for action: MediaItemAction) -> MediaItem? {
        switch action {
        case .goToSeason:
            return seasonNavigationTarget
        case .goToMovie, .goToEpisode:
            // The item itself is the destination; the page re-fetches full
            // detail by id.
            return self
        case .markWatched, .markUnwatched, .markWatchedUpToHere,
             .addToWatchlist, .removeFromWatchlist, .refreshMetadata,
             .startDownload, .pauseDownload, .resumeDownload, .removeDownload:
            return nil
        }
    }

    /// What "add to watchlist" means for this row.
    ///
    /// An episode is not watchlistable — you cannot save "episode 4" for later in
    /// any sense a viewer means — so the subject of the gesture is the show it
    /// belongs to. Without this the button simply vanished wherever a hero fronted
    /// an episode, which is most of Continue Watching and every series page that
    /// has resolved its next episode.
    ///
    /// Falls back to the item itself when the show cannot be identified, so the
    /// button is never wired to something arbitrary.
    public var watchlistSubject: MediaItem {
        guard kind == .episode || kind == .season else { return self }
        guard let seriesID else { return self }
        return MediaItem(
            id: seriesID,
            title: parentTitle ?? title,
            kind: .series,
            sourceAccountID: sourceAccountID
        )
    }

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
