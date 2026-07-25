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

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.mediaItemActionHandler) private var handler
    @Environment(\.mediaItemActionContext) private var context
    @Environment(\.mediaItemNavigator) private var navigator

    public init(item: MediaItem) {
        self.item = item
    }

    /// Padding that places the GLYPH `inset` from the artwork edge while keeping
    /// the full tap target. The target is deliberately larger than the glyph, so
    /// padding the control by `inset` would push the dots much further in than
    /// asked; this subtracts the target's own slack instead.
    private var edgePadding: CGFloat {
        max(metrics.artworkMenuInset - (metrics.artworkMenuTargetSize - metrics.artworkMenuGlyphSize) / 2, 0)
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
                    .font(.system(size: metrics.artworkMenuGlyphSize, weight: .bold))
                    .foregroundStyle(.white)
                    // Flat by design: legibility comes from the artwork scrim, not
                    // from a shadow on the glyph. The tap target is deliberately
                    // larger than the glyph — sizing the frame TO the glyph (the
                    // first cut) produced a 21pt control, half Apple's minimum.
                    .frame(
                        width: metrics.artworkMenuTargetSize,
                        height: metrics.artworkMenuTargetSize
                    )
                    .contentShape(Circle())
            }
            .padding(edgePadding)
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
             .addToWatchlist, .removeFromWatchlist, .refreshMetadata,
             .startDownload, .pauseDownload, .resumeDownload, .removeDownload:
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
/// The legibility wash behind artwork chrome.
///
/// One definition so every surface that draws controls on artwork darkens it the
/// same way — and so those controls can stay FLAT. Per-element drop shadows were
/// doing this job before, which made each control carry its own halo and read as
/// a sticker sitting on the image rather than part of it.
///
/// The two-ended vertical form is taken from the iOS episode rows, which had it
/// first and had it right: controls live in the top and bottom bands, so darken
/// exactly those and leave the subject in the middle untouched. (A radial wash
/// from one corner — the earlier tvOS treatment — dims the subject on its way
/// across the frame and only ever protects one corner.)
public struct MediaArtworkChromeScrim: View {
    private let hasTopChrome: Bool
    private let hasBottomChrome: Bool

    public init(top: Bool, bottom: Bool) {
        self.hasTopChrome = top
        self.hasBottomChrome = bottom
    }

    public var body: some View {
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }

    private var stops: [Gradient.Stop] {
        [
            .init(color: .black.opacity(hasTopChrome ? 0.5 : 0), location: 0),
            .init(color: .clear, location: 0.34),
            .init(color: .clear, location: 0.62),
            .init(color: .black.opacity(hasBottomChrome ? 0.58 : 0), location: 1),
        ]
    }
}

#endif
