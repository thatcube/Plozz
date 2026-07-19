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
    let layout: [HomeRowLayout]
    /// Whether the per-profile hero carousel is enabled. When `true` the skeleton
    /// mirrors the hero-on Home: an **empty** full-height hero area (no backdrop
    /// fill, no shimmer — a full-screen shimmer would be far too much) with soft
    /// placeholder bars for the title-adjacent metadata / overview text and the
    /// action buttons, and the rows pulled up beneath so Continue Watching peeks in
    /// — matching `HomeView`'s loaded hero layout. When `false` it's the classic
    /// rows-only skeleton, unchanged. This is only ever seen on a genuine first
    /// launch: once Home has loaded once, `HomeContentStore` paints the real hero +
    /// rows instantly from cache and this loading state is skipped entirely.
    var heroActive: Bool = false
    /// How long loading must persist before the skeleton fades in.
    var appearDelay: Duration = .milliseconds(150)

    @State private var visible = false
    /// The rail's measured viewport width, used to render exactly enough
    /// placeholder cards to fill the screen for the *current* density (see
    /// `cardCount`). Measured via a background reader so it never perturbs layout.
    @State private var availableWidth: CGFloat = 0

    @Environment(\.plozzMetrics) private var metrics

    /// tvOS full-screen width, used only as a first-frame fallback before the
    /// real viewport width is measured — so the very first render still shows a
    /// screen-filling row instead of a single card.
    private static let fallbackWidth: CGFloat = 1920

    private var rows: [HomeRowLayout] {
        layout.isEmpty ? HomeRowKind.defaultSkeletonLayout : layout
    }

    private var measuredWidth: CGFloat {
        availableWidth > 0 ? availableWidth : Self.fallbackWidth
    }

    var body: some View {
        Group {
            if heroActive {
                heroLayout
            } else {
                classicLayout
            }
        }
        .allowsHitTesting(false)
        .background {
            // Measure the available width without affecting layout, so the number
            // of skeleton cards tracks how many actually fit at the current density.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        availableWidth = newWidth
                    }
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: visible)
        .task {
            try? await Task.sleep(for: appearDelay)
            visible = true
        }
    }

    /// Classic rows-only skeleton (hero disabled) — unchanged behaviour.
    private var classicLayout: some View {
        ScrollView {
            rowsStack
                .padding(.vertical, PlozzTheme.Metrics.screenVerticalPadding)
        }
        .scrollClipDisabled()
        .scrollDisabled(true)
    }

    /// Hero-on skeleton: an empty full-height hero area with placeholder text +
    /// buttons, then the rows pulled up beneath (Continue Watching peeking). Mirrors
    /// `HomeView`'s hero layout 1:1 via the shared `HomeHeroLayout` constants — the
    /// same negative `rowOverlap` and top-safe-area bleed — so nothing shifts when
    /// the real hero swaps in.
    private var heroLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HomeHeroSkeletonView()
                rowsStack
                    .padding(.top, -HomeHeroLayout.rowOverlap)
                    .padding(.bottom, PlozzTheme.Metrics.screenVerticalPadding)
            }
        }
        .scrollClipDisabled()
        .scrollDisabled(true)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The stacked skeleton rows, shared by both layouts.
    private var rowsStack: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            ForEach(rows, id: \.kind) { row in
                skeletonRow(row)
            }
        }
    }

    @ViewBuilder
    private func skeletonRow(_ row: HomeRowLayout) -> some View {
        let kind = row.kind
        // Mirrors MediaRowView's title + horizontal rail layout and paddings so
        // the skeleton occupies the same vertical space as the real row.
        VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
            // Reserve the *exact* height of MediaRowView's title — a hidden Text in
            // the real (density-scaled) header font — with the placeholder pill
            // overlaid. Matching the title height is load-bearing: a shorter title
            // bar makes the cards sit higher, so the whole row drops when the real
            // (taller) title loads in.
            Text(" ")
                .font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
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
                    ForEach(0..<cardCount(for: row), id: \.self) { _ in
                        SkeletonCardView(style: cardStyle(for: kind))
                            .frame(width: cardWidth(for: kind))
                    }
                }
                .padding(.leading, PlozzTheme.Metrics.screenPadding)
                .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                .padding(.top, metrics.railTopPadding)
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

    /// The layout slot reserved for each skeleton card — must equal
    /// `MediaRowView.cardSlotWidth` so the placeholder cards sit at the *exact*
    /// same pitch as the real row. A poster's glass equals `posterWidth`; a
    /// landscape card's glass is `landscapeWidth + 2 * cardInset`
    /// (`landscapeCardSlotWidth`), so pinning to the bare `landscapeWidth` would
    /// make the placeholders 32 pt too narrow and bunch them closer than the real
    /// Continue Watching / Libraries cards.
    private func cardWidth(for kind: HomeRowKind) -> CGFloat {
        cardStyle(for: kind) == .landscape ? metrics.landscapeCardSlotWidth : metrics.posterWidth
    }

    /// How many placeholder cards to render for a row. We show the count the row
    /// actually rendered last load (`row.count`) but never more than fit on the
    /// current screen at this density — so a sparse row (e.g. 3 Continue Watching
    /// items) shows just three instead of a screen full that then collapses, while
    /// a full row still fills the viewport. `count == 0` means "unknown" (first
    /// launch), so we fall back to filling the screen.
    private func cardCount(for row: HomeRowLayout) -> Int {
        let fits = fittingCardCount(for: row.kind)
        return row.count > 0 ? min(row.count, fits) : fits
    }

    /// The number of cards of `kind`'s size that fill the measured viewport, plus
    /// one that peeks in from the trailing edge — matching how a real, scrollable
    /// `MediaRowView` looks at rest. Derived from the card slot pitch
    /// (`cardWidth + cardSpacing`) and the row's leading screen inset, so it tracks
    /// the display-density setting automatically instead of hardcoding a count.
    private func fittingCardCount(for kind: HomeRowKind) -> Int {
        let slot = cardWidth(for: kind)
        guard slot > 0 else { return 1 }
        let pitch = slot + metrics.cardSpacing
        let usable = max(measuredWidth - PlozzTheme.Metrics.screenPadding, 0)
        let fit = Int(ceil((usable + metrics.cardSpacing) / pitch))
        return max(fit + 1, 1)
    }
}

/// The hero portion of the loading skeleton, shown only when the hero is enabled.
///
/// Deliberately renders **no backdrop** — the hero fills the whole display, and a
/// full-screen shimmer/fill while loading would be far too heavy (that's the whole
/// point of not skeletoning the artwork). Instead the artwork area is left empty
/// (the app background shows through) and only the lower-third *text and buttons*
/// get soft, shimmering placeholders, laid out at the same position as the real
/// hero's content column (via the shared `HomeHeroLayout` insets). The big title /
/// logo is intentionally omitted: on the rare first launch we can't know whether a
/// title exists as a logo image or as text, and once Home has loaded once the real
/// hero paints instantly from cache (see `HomeContentStore`) so this is never seen.
struct HomeHeroSkeletonView: View {
    /// Button pill footprint — mirrors `HomeHeroView.heroPill` (28pt label +
    /// 18pt vertical / 30pt horizontal padding, ~34pt icon box).
    private static let pillHeight: CGFloat = 70
    private static let playPillWidth: CGFloat = 180
    private static let iconPillWidth: CGFloat = 94

    var body: some View {
        contentColumn
            // Reserve the full hero height and pin the placeholders to the bottom
            // third, exactly like the real hero content column — so Continue
            // Watching (pulled up by `HomeHeroLayout.rowOverlap`) peeks in at the
            // same spot. No `.background`: the backdrop stays empty while loading.
            .frame(maxWidth: .infinity, minHeight: HomeHeroLayout.screenHeight, alignment: .bottomLeading)
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: HomeHeroLayout.contentColumnSpacing) {
            // Metadata line (year / rating / runtime) — one short bar.
            capsule(width: 150, height: 26)

            // Overview — a couple of soft text lines.
            VStack(alignment: .leading, spacing: 10) {
                capsule(width: 880, height: 20)
                capsule(width: 600, height: 20)
            }
            .padding(.top, 2)

            // Action buttons — Play + three icon pills, matching the real hero row.
            HStack(spacing: 24) {
                capsule(width: Self.playPillWidth, height: Self.pillHeight)
                capsule(width: Self.iconPillWidth, height: Self.pillHeight)
                capsule(width: Self.iconPillWidth, height: Self.pillHeight)
                capsule(width: Self.iconPillWidth, height: Self.pillHeight)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PlozzTheme.Metrics.screenVerticalPadding)
        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
        .padding(.leading, HomeHeroLayout.contentLeadingPadding)
        .padding(.bottom, HomeHeroLayout.contentBottomInset)
        // Shimmer stays on the small placeholder shapes only — never the backdrop.
        .shimmering()
    }

    private func capsule(width: CGFloat, height: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(Color.plozzSkeletonFill)
            .frame(width: width, height: height)
    }
}

#endif
