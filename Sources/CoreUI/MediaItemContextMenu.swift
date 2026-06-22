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

    public init(item: MediaItem) {
        self.item = item
    }

    public func body(content: Content) -> some View {
        let actions = handler?.actions(for: item, context: context) ?? []
        if let handler, !actions.isEmpty {
            content.contextMenu {
                ForEach(actions) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        handler.perform(action, on: item, context: context)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            }
        } else {
            content
        }
    }
}

#endif
