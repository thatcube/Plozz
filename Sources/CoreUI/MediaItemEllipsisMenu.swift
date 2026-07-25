#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// A tappable "…" menu drawn on media artwork, populated from the same
/// environment action handler that backs the press-and-hold context menu.
///
/// Exists because a long-press is discoverable on tvOS (where every card is
/// focused before it's chosen) but effectively hidden on a touch card — the
/// episode rows on the detail page already had a visible affordance while
/// Continue Watching cards only had the hidden gesture. Sharing one definition
/// keeps both surfaces offering the same actions.
///
/// Renders nothing when no handler is installed or the item has no actions, so
/// it never leaves a dead control on a card.
public struct MediaItemEllipsisMenu: View {
    private let item: MediaItem
    private let diameter: CGFloat

    @Environment(\.mediaItemActionHandler) private var handler
    @Environment(\.mediaItemActionContext) private var context
    @Environment(\.mediaItemNavigator) private var navigator

    public init(item: MediaItem, diameter: CGFloat) {
        self.item = item
        self.diameter = diameter
    }

    public var body: some View {
        let actions = availableActions()
        if !actions.isEmpty {
            Menu {
                ForEach(actions) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        perform(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: diameter * 0.5, weight: .bold))
                    .foregroundStyle(.white)
                    // Flat by design: legibility comes from the artwork scrim, not
                    // from a shadow on the glyph.
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
            }
            .accessibilityLabel("More actions for \(item.title)")
        }
    }

    private func availableActions() -> [MediaItemAction] {
        let actions = handler?.actions(for: item, context: context) ?? []
        return actions.filter { !$0.isNavigation || navigator != nil }
    }

    private func perform(_ action: MediaItemAction) {
        if action.isNavigation {
            navigator.map { navigate(action, using: $0) }
        } else {
            handler?.perform(action, on: item, context: context)
        }
    }

    private func navigate(_ action: MediaItemAction, using navigate: (MediaItem) -> Void) {
        switch action {
        case .goToSeason:
            item.seasonNavigationTarget.map(navigate)
        case .goToMovie:
            navigate(item)
        case .markWatched, .markUnwatched, .markWatchedUpToHere,
             .addToWatchlist, .removeFromWatchlist, .refreshMetadata:
            break
        }
    }
}

/// The legibility wash behind artwork chrome.
///
/// One definition so every surface that draws controls on artwork darkens it the
/// same way — and so those controls can stay FLAT. Per-element drop shadows were
/// doing this job before, which made each control carry its own halo and read as
/// a sticker sitting on the image rather than part of it.
public struct MediaArtworkChromeScrim: View {
    private let corners: Corners

    public enum Corners: Equatable, Sendable {
        /// Bottom-leading wash for a resume chip.
        case bottomLeading
        /// Top wash for a "…" menu / status badge.
        case top
    }

    public init(_ corners: Corners) {
        self.corners = corners
    }

    public var body: some View {
        switch corners {
        case .bottomLeading:
            GeometryReader { proxy in
                RadialGradient(
                    colors: [.black.opacity(0.55), .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.8
                )
            }
            .allowsHitTesting(false)
        case .top:
            // Shallower and softer than the bottom wash: it only has to carry a
            // glyph, and a heavy top band would read as a letterbox bar.
            LinearGradient(
                colors: [.black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }
}

#endif
