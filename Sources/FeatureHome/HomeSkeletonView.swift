#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// A 1:1 placeholder for the Home screen shown while content loads. It renders
/// the *same* row structure the loaded view will (driven by a `[HomeRowKind]`
/// layout — ideally the one persisted from last launch), using `SkeletonCardView`
/// placeholders that share `PosterCardView`'s exact geometry so nothing shifts
/// when real content swaps in.
///
/// Two deliberate behaviours:
///  * **Delay gate** — the skeleton stays invisible for a short grace period and
///    only fades in if loading actually drags on. Warm launches (now common with
///    the cached Plex token) finish before the gate opens, so the user never sees
///    a skeleton flash on a fast load.
///  * **Non-interactive** — the whole tree ignores hit-testing and its cards are
///    non-focusable, so the focus engine never anchors on a placeholder.
struct HomeSkeletonView: View {
    let layout: [HomeRowKind]
    /// How long loading must persist before the skeleton fades in.
    var appearDelay: Duration = .milliseconds(150)

    @State private var visible = false

    @Environment(\.plozzMetrics) private var metrics

    private var rows: [HomeRowKind] {
        layout.isEmpty ? HomeRowKind.defaultSkeletonLayout : layout
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                ForEach(rows, id: \.self) { kind in
                    skeletonRow(kind)
                }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: visible)
        .task {
            try? await Task.sleep(for: appearDelay)
            visible = true
        }
    }

    @ViewBuilder
    private func skeletonRow(_ kind: HomeRowKind) -> some View {
        // Mirrors MediaRowView's title + horizontal rail layout and paddings so
        // the skeleton occupies the same vertical space as the real row.
        VStack(alignment: .leading, spacing: 16) {
            // Reserve the *exact* height of MediaRowView's title — a hidden Text in
            // the real font (system 32 bold) — with the placeholder pill overlaid.
            // Matching the title height is load-bearing: a shorter title bar makes
            // the cards sit higher, so the whole row drops when the real (taller)
            // title loads in.
            Text(" ")
                .font(.system(size: 32, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.plozzSkeletonFill)
                        .frame(width: 220, height: 26)
                        .padding(.leading, PlozzTheme.Metrics.screenPadding)
                }
                .shimmering()
            
            // Mirror MediaRowView exactly: the cards live in a *horizontal*
            // ScrollView (scrolling disabled here). This is load-bearing — a plain
            // HStack of oversized cards has an ideal width wider than the screen, so
            // it overflows its column and the whole row drifts out of the tvOS
            // overscan safe area (cards bleed off the left edge). The ScrollView
            // clips its frame to the viewport, so the leading inset matches the real
            // row 1:1.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: metrics.cardSpacing) {
                    ForEach(0..<cardCount(for: kind), id: \.self) { _ in
                        SkeletonCardView(style: cardStyle(for: kind))
                            .frame(width: cardWidth(for: kind))
                    }
                }
                .padding(.leading, PlozzTheme.Metrics.screenPadding)
                .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                .padding(.top, 16)
                .padding(.bottom, metrics.railVerticalPadding)
            }
            .scrollClipDisabled()
            .scrollDisabled(true)
        }
    }

    /// Continue Watching and the Libraries tiles use the wide landscape card;
    /// every other row uses portrait posters — matching the real Home.
    private func cardStyle(for kind: HomeRowKind) -> SkeletonCardView.Style {
        switch kind {
        case .continueWatching, .libraries: return .landscape
        case .watchlist, .recentlyAdded: return .poster
        }
    }

    private func cardWidth(for kind: HomeRowKind) -> CGFloat {
        cardStyle(for: kind) == .landscape ? metrics.landscapeWidth : metrics.posterWidth
    }

    /// Enough placeholders to fill the 10-foot screen width for each card size.
    private func cardCount(for kind: HomeRowKind) -> Int {
        cardStyle(for: kind) == .landscape ? 4 : 6
    }
}

#endif
