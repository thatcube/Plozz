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
                    .accessibilityLabel(Text(action.title))
                    .accessibilityValue(
                        action.accessibilityState.map(Text.init) ?? Text(verbatim: "")
                    )
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
            if let navigator, let target = item.navigationTarget(for: action) {
                navigator(target)
            }
        } else {
            handler?.perform(action, on: item, context: context)
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
    private let bottomStart: CGFloat
    private let bottomDepth: CGFloat

    /// - Parameter bottomStart: where the bottom ramp begins, as a fraction of
    ///   the artwork's height. The default half-way point suits a card whose
    ///   chrome sits directly on the picture.
    /// - Parameter bottomDepth: how dark that ramp gets at the very bottom edge.
    ///   The default is the depth chrome needs when nothing else is darkening the
    ///   artwork; a caller that lays down its own wash over the same region (a
    ///   Continue Watching card and its reflection — see ``ExtendedArtworkFill``)
    ///   passes less, because the two compound and would otherwise reach black.
    public init(
        top: Bool,
        bottom: Bool,
        bottomStart: CGFloat = 0.52,
        bottomDepth: CGFloat = 0.78
    ) {
        self.hasTopChrome = top
        self.hasBottomChrome = bottom
        self.bottomStart = min(0.95, max(0.2, bottomStart))
        self.bottomDepth = min(1, max(0, bottomDepth))
    }

    public var body: some View {
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }

    /// The bottom stop has to be dark enough that chrome sitting on it reads the
    /// SAME on a black poster and a white one. The chrome's own tones are fixed
    /// (see ``PlozzMediaChrome``), so any variance left in this backdrop shows up
    /// directly as the text looking bright on one card and washed out on the next
    /// — which is exactly what a translucent 0.58 did over pale artwork. Deeper,
    /// and starting its ramp higher, gives a consistent bed to read against.
    ///
    /// Both ramps are **eased** rather than straight lines. A linear ramp changes
    /// at a constant rate, so where it begins the rate goes from nothing to
    /// something within one row, and the eye reads that as an edge drawn across
    /// the artwork. Easing in from zero slope (see ``ArtworkGradientRamp``) makes
    /// the darkening start where it is too slight to notice, which is the only
    /// way it can start without announcing itself.
    private var stops: [Gradient.Stop] {
        let quiet = min(0.34, bottomStart)
        var stops: [Gradient.Stop] = []
        if hasTopChrome {
            stops += ArtworkGradientRamp.fadingStops(peak: 0.5, from: 0, to: quiet)
        } else {
            stops.append(.init(color: .clear, location: 0))
            stops.append(.init(color: .clear, location: quiet))
        }
        stops.append(.init(color: .clear, location: bottomStart))
        if hasBottomChrome {
            stops += ArtworkGradientRamp.stops(peak: bottomDepth, from: bottomStart, to: 1)
        } else {
            stops.append(.init(color: .clear, location: 1))
        }
        return stops
    }
}

#endif
