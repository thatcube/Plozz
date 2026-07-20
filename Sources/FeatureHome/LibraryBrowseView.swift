#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHomeCore

/// A sparse, lazily-loaded poster grid for browsing a single library. Each cell
/// is the shared `CoreUI.PosterCardView` (`.poster` style) — identical to Home's
/// "Recently Added" row — flowing as many fixed-width columns as fit the width.
///
/// After the first page loads (which reports the library's total size), the grid
/// is laid out for the *entire* library at once: every slot renders a card, and
/// each card lazily triggers loading of the page it belongs to as it scrolls
/// into view. Not-yet-loaded slots show a placeholder until their page arrives,
/// so even libraries with thousands of items scroll smoothly and never block on
/// a single all-items request.
public struct LibraryBrowseView: View {
    @State private var viewModel: LibraryBrowseViewModel
    /// Tracks which items we've already warmed artwork for. A reference type (not a
    /// `@State` `Set`) so inserting during scroll does not invalidate the view body.
    @State private var artworkPrefetch = ArtworkPrefetchTracker()
    /// The rail letter that currently holds focus, or `nil` when focus is in the
    /// grid. Drives the fly-through highlight + the transient jumbo letter bubble.
    @State private var railFocusedLetter: String?
    /// Latches `true` once the grid has been scrolled a few rows into a name-sorted
    /// library, then stays up. Keeps the rail out of the way on first entry (when
    /// you're just landing on the top of the list) and only brings it in once
    /// you're actually flying through content. Reset when the rail's eligibility
    /// goes away (a non-name sort) so re-entering name sort re-arms the reveal.
    @State private var railHasRevealed = false
    private let title: String
    private let spoilerSettings: SpoilerSettings
    private let onSelect: (MediaItem) -> Void

    @Environment(\.plozzMetrics) private var metrics

    public init(
        viewModel: LibraryBrowseViewModel,
        title: String,
        spoilerSettings: SpoilerSettings = .default,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.title = title
        self.spoilerSettings = spoilerSettings
        self.onSelect = onSelect
    }

    public var body: some View {
        // Shared dense "Browse" wall — flexible columns from the live density
        // metrics so each glass tile stretches to fill its column and the wall
        // scales with the UI-density setting. Search reuses the same spec so the
        // two surfaces match.
        let columns = metrics.posterColumns
        return ContentStateView(
            state: viewModel.state,
            emptyMessage: "This library is empty.",
            onRetry: { Task { await viewModel.loadFirstPage() } }
        ) { total in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
                        header
                        LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
                            ForEach(0..<total, id: \.self) { index in
                                LibraryGridCell(
                                    slot: viewModel.slot(at: index),
                                    index: index,
                                    spoilerSettings: spoilerSettings,
                                    onSelect: onSelect,
                                    onAppear: { idx in
                                        await viewModel.itemAppeared(at: idx)
                                        prefetchArtwork(aheadFrom: idx)
                                    },
                                    onDisappear: { viewModel.itemDisappeared(at: $0) }
                                )
                                // Explicit scroll identity so the rail's
                                // `scrollTo(startIndex)` lands on the right row.
                                .id(index)
                            }
                        }
                        .padding(.horizontal, HomeLayout.horizontalPadding)
                        .padding(.bottom, PlozzTheme.Metrics.screenVerticalPadding)
                        .focusSection()
                    }
                    .padding(.top, PlozzTheme.Spacing.large)
                    #if canImport(UIKit)
                    // Suppress the native scroll indicator while the alphabet rail
                    // is up (it can't be reliably killed by `.scrollIndicators`, and
                    // it drifts out of sync with the letters). Attached as a
                    // NON-LAZY `.background` on the scroll *content* so it (a) lives
                    // inside the UIScrollView — its superview walk finds it — and
                    // (b) is never culled the way a lazy `LazyVStack` child is the
                    // moment it scrolls off, which is exactly when we need it alive.
                    .background(
                        ScrollIndicatorHider(hidden: isRailVisible)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    )
                    #endif
                }
                // Never clip a focused card's lift, shadow or border.
                .scrollClipDisabled()
                // Rail + its "you are here" highlight live in a dedicated layer so
                // that tracking `topVisibleIndex` (which ticks on every cell that
                // scrolls in or out) re-renders only this small ~26-letter rail —
                // never the parent's (potentially thousands of) poster cells.
                .overlay(alignment: .trailing) {
                    LibraryRailLayer(
                        viewModel: viewModel,
                        railFocusedLetter: $railFocusedLetter,
                        railHasRevealed: $railHasRevealed,
                        revealThreshold: railRevealThreshold,
                        proxy: proxy
                    )
                }
                // A transient jumbo letter that appears while flying the rail so
                // the current jump target is legible from across the room.
                .overlay(alignment: .center) {
                    if let letter = railFocusedLetter {
                        LetterJumpBubble(letter: letter)
                            .transition(.scale.combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: railFocusedLetter)
                // Re-arm the reveal whenever the rail stops being eligible (e.g. a
                // switch to a non-name sort), so the next name sort starts hidden.
                .onChange(of: viewModel.showsLetterRail) { _, shows in
                    if !shows { railHasRevealed = false }
                }
            }
        }
        // Browse is a full-screen sub-page: hide the top tab bar so it reads as a
        // dedicated destination with no navigation chrome pinned at the top.
        .toolbar(.hidden, for: .tabBar)
        .task { if viewModel.state.value == nil { await viewModel.loadFirstPage() } }
        .background {
            if viewModel.isMediaShare {
                ShareCatalogRefreshObserver(shareID: viewModel.sourceServerID) {
                    Task { await viewModel.refreshAfterCatalogChange() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            }
        }
        .task {
            // Opt-in (PLZXMEM=1) memory/background-activity sampler. Fully inert
            // when disabled — returns before starting any timer or keep-alive loop.
            guard BrowseDiagnostics.isEnabled else { return }
            BrowseDiagnostics.event("screen browse+")
            let sampler = BrowseDiagnostics.startSampler(label: "browse") {
                let decoded = ArtworkImageCache.shared.currentStats()
                let responses = ArtworkSession.cacheUsage()
                let mb = Double(1024 * 1024)
                return (
                    count: decoded.count,
                    decodedMB: decoded.costMB,
                    responseMemoryMB: Double(responses.memoryBytes) / mb,
                    responseDiskMB: Double(responses.diskBytes) / mb
                )
            }
            defer {
                sampler?.cancel()
                BrowseDiagnostics.event("screen browse-")
            }
            // Keep alive for the lifetime of this view; cancelled on disappear.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
    }

    /// Whether the alphabet rail should currently be on screen: it must be
    /// eligible (name sort with a resolved index) *and* the user must have scrolled
    /// past the reveal threshold at least once this sort.
    private var isRailVisible: Bool { viewModel.showsLetterRail && railHasRevealed }

    /// How far down (in grid indices) the top of the list must scroll before the
    /// rail reveals — a couple of poster rows, so it only shows up once you're
    /// actually flying through the library rather than sitting at the top.
    private var railRevealThreshold: Int { max(1, metrics.posterColumns.count) * 2 }

    /// The library title and Sort control. It scrolls *with* the grid (it is the
    /// first row of the scroll content), so nothing is pinned to the top of the
    /// sub-page.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.largeTitle.bold())
            Spacer(minLength: PlozzTheme.Spacing.large)
            sortControl
        }

        .padding(.horizontal, HomeLayout.horizontalPadding)
        .focusSection()
    }

    /// A focusable native sort menu.
    private var sortControl: some View {
        Menu {
            Picker("Sort By", selection: sortFieldBinding) {
                ForEach(SortField.allCases, id: \.self) { field in
                    Text(field.displayName).tag(field)
                }
            }
            Picker("Order", selection: sortDirectionBinding) {
                ForEach(SortDirection.allCases, id: \.self) { direction in
                    Text(direction.displayName).tag(direction)
                }
            }
        } label: {
            Label("Sort: \(viewModel.sort.field.displayName)", systemImage: "arrow.up.arrow.down")
        }
    }

    private var sortFieldBinding: Binding<SortField> {
        Binding(
            get: { viewModel.sort.field },
            set: { field in
                Task {
                    await viewModel.setSort(
                        CoreModels.SortDescriptor(
                            field: field,
                            direction: field.defaultDirection
                        )
                    )
                }
            }
        )
    }

    private var sortDirectionBinding: Binding<SortDirection> {
        Binding(
            get: { viewModel.sort.direction },
            set: { direction in
                Task { await viewModel.setSort(CoreModels.SortDescriptor(field: viewModel.sort.field, direction: direction)) }
            }
        )
    }

    /// Warms decoded poster art for a short forward window once a cell appears so
    /// rapid right-hold scrolling reuses ready thumbnails instead of flashing gray
    /// placeholders.
    private func prefetchArtwork(aheadFrom index: Int) {
        #if canImport(UIKit)
        guard index >= 0, index < viewModel.totalCount else { return }
        let upper = min(index + 10, viewModel.totalCount - 1)
        guard index <= upper else { return }
        for candidateIndex in index...upper {
            guard let candidate = viewModel.item(at: candidateIndex) else { continue }
            guard artworkPrefetch.seen.insert(candidate.id).inserted else { continue }
            for url in candidate.artworkCandidates(for: .poster).prefix(2) {
                ArtworkImageCache.shared.prefetch(url, variant: .posterCard)
            }
        }
        #endif
    }
}

/// Render-isolated scan-completion observer. Scan/enrichment progress mutates the
/// whole status dictionary frequently; containing that observation here prevents
/// progress ticks from invalidating the poster grid.
private struct ShareCatalogRefreshObserver: View {
    let shareID: String
    let onRefresh: () -> Void

    @Environment(ShareScanStatusModel.self) private var status: ShareScanStatusModel?

    private var lastScanAt: Date? { status?.byShare[shareID]?.lastScanAt }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: lastScanAt) { oldValue, newValue in
                guard newValue != nil, newValue != oldValue else { return }
                onRefresh()
            }
            .accessibilityHidden(true)
    }
}

/// One grid cell, bound to its observable ``LibrarySlot``. Reading `slot.item` in
/// this view's own body is what confines a page fill's re-render to just the cells
/// whose slots changed — mutating one slot invalidates only the cells observing
/// it, not every cell that ever read the parent `loaded` array. That per-cell
/// isolation is the fix for the fast-SMB-paging scroll churn.
private struct LibraryGridCell: View {
    let slot: LibrarySlot?
    let index: Int
    let spoilerSettings: SpoilerSettings
    let onSelect: (MediaItem) -> Void
    let onAppear: (Int) async -> Void
    let onDisappear: (Int) -> Void

    var body: some View {
        Group {
            if let item = slot?.item {
                // Shared poster card — identical to Home's "Recently Added" row.
                PosterCardView(
                    item: item,
                    style: .poster,
                    spoilerSettings: spoilerSettings,
                    enablesAsyncArtworkFallback: false
                ) {
                    onSelect(item)
                }
            } else {
                PosterPlaceholderView()
            }
        }
        .task(id: index) { await onAppear(index) }
        .onDisappear { onDisappear(index) }
    }
}

/// A poster-shaped, redacted placeholder for a not-yet-loaded grid slot. Sized to
/// match `PosterCardView`'s `.poster` artwork so columns stay aligned while a page
/// is in flight. Inert (non-focusable) so focus skips over it.
private struct PosterPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.posterArtCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text("Loading").font(.headline)
                Text(" ").font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .redacted(reason: .placeholder)
        }
        .padding(10)
    }
}

/// Reference-typed tracker of already-prefetched artwork item IDs. Kept in
/// `@State` as a *class* so mutating its contents while scrolling does not
/// invalidate the SwiftUI view body — a value-type `@State` `Set` would trigger a
/// full-body re-render on every newly-seen item, hitching the scroll exactly when
/// flying into not-yet-loaded content.
private final class ArtworkPrefetchTracker {
    var seen: Set<String> = []
}

/// The alphabet rail plus its scroll-position highlight, isolated into its own
/// view. Observing `topVisibleIndex` — which ticks on every cell that scrolls in
/// or out — only re-renders these ~26 letters here, not the parent's (potentially
/// thousands of) poster cells. Also owns the "reveal after a couple of rows" latch
/// for the same reason. The current letter is passed into `LibraryLetterRail` as a
/// plain value, so its heavier body only re-runs when the letter actually changes.
private struct LibraryRailLayer: View {
    let viewModel: LibraryBrowseViewModel
    @Binding var railFocusedLetter: String?
    @Binding var railHasRevealed: Bool
    let revealThreshold: Int
    let proxy: ScrollViewProxy

    private var isRailVisible: Bool { viewModel.showsLetterRail && railHasRevealed }

    /// The letter to highlight as "current": the focused rail letter while flying
    /// the rail, otherwise the letter owning the top-most visible grid row.
    private var currentLetter: String? {
        if let railFocusedLetter { return railFocusedLetter }
        return viewModel.letter(forIndex: viewModel.topVisibleIndex ?? 0)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if isRailVisible {
                LibraryLetterRail(
                    entries: viewModel.letterEntries,
                    currentLetter: currentLetter,
                    focusedLetter: $railFocusedLetter,
                    onScrollToLetter: { entry in
                        viewModel.prepareJump(toIndex: entry.startIndex)
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(entry.startIndex, anchor: .top)
                        }
                    }
                )
                // Gate re-renders on the rail's meaningful inputs (entries +
                // current letter). This layer re-evaluates on every cell that
                // scrolls in or out (to track `topVisibleIndex`), but the rail's
                // heavier body — 26 letters, the glass bubble, the magnification —
                // only needs to rebuild when the highlighted letter actually
                // changes, so focus movement between posters stays smooth.
                .equatable()
                // Nudge the rail into the trailing gutter (where the native scroll
                // indicator used to sit) so it clears the poster wall instead of
                // hugging the last column, and lift it up a touch so it sits above
                // the vertical centre line.
                .offset(x: 54, y: -40)
            }
        }
        // Arm the rail only after the user has flown a few rows past the top of a
        // name-sorted library, then latch it on. Driven off both `topVisibleIndex`
        // and `showsLetterRail` so a letter index that finishes building *after*
        // the user has already scrolled past the threshold still reveals the rail
        // promptly, instead of waiting for the next row to scroll in.
        .onChange(of: viewModel.topVisibleIndex) { _, _ in revealRailIfNeeded() }
        .onChange(of: viewModel.showsLetterRail) { _, _ in revealRailIfNeeded() }
    }

    /// Latch the rail on once a name-sorted library has scrolled a couple of rows
    /// past the top. `topVisibleIndex` is the smallest visible grid index, so it
    /// crosses `revealThreshold` once a couple of rows have scrolled off the top.
    private func revealRailIfNeeded() {
        guard viewModel.showsLetterRail, !railHasRevealed,
              let index = viewModel.topVisibleIndex, index >= revealThreshold else { return }
        withAnimation(.easeOut(duration: 0.25)) { railHasRevealed = true }
    }
}

/// The Infuse-style vertical A–Z fast-scroll rail pinned to the trailing edge of
/// the browse grid. Each present letter is a focusable button; moving focus onto
/// a letter scrolls the grid to that letter's first item (fly-through), and
/// pressing it jumps there too. The letter whose range currently sits at the top
/// of the grid is highlighted so it doubles as a position indicator.
///
/// Only shown when the grid is name-sorted (the view model supplies the per-letter
/// offsets), so it never appears for date/rating/etc. sorts where letters are
/// meaningless.
private struct LibraryLetterRail: View, Equatable {
    let entries: [LibraryLetterIndexEntry]
    let currentLetter: String?
    @Binding var focusedLetter: String?
    let onScrollToLetter: (LibraryLetterIndexEntry) -> Void

    @FocusState private var focus: String?
    @Namespace private var bubbleNamespace

    // Only the value inputs that affect rendering participate; the binding and the
    // scroll closure are excluded (they can't be compared and don't change the
    // rail's appearance). Internal @FocusState changes still re-render as usual.
    static func == (lhs: LibraryLetterRail, rhs: LibraryLetterRail) -> Bool {
        lhs.currentLetter == rhs.currentLetter && lhs.entries == rhs.entries
    }

    var body: some View {
        // Resolve the "cursor" row once per render (not per letter) so the whole
        // magnification pass is O(n) rather than O(n²) — this rail re-renders on
        // every scroll tick while it marks the top-visible position.
        let activeIndex = activeIndex
        return VStack(spacing: 2) {
            ForEach(Array(entries.enumerated()), id: \.element.letter) { index, entry in
                let isActive = entry.letter == currentLetter
                let magnification = magnification(forRowAt: index, activeIndex: activeIndex)
                Button {
                    onScrollToLetter(entry)
                } label: {
                    Text(entry.letter)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    LetterRailButtonStyle(isCurrent: isActive, magnification: magnification)
                )
                // A single liquid-glass pill lives behind whichever letter is active
                // and rides `matchedGeometryEffect`, so changing the active letter
                // fluidly slides/morphs the *same* bubble to the new slot instead of
                // cross-fading a separate highlight per letter.
                .background {
                    if isActive {
                        LetterRailBubble()
                            // Inflate the pill beyond the glyph's frame so it reads
                            // as a generous bubble: mostly horizontally (no vertical
                            // neighbours to collide with there) plus a little
                            // vertically — the magnified active frame leaves a gap
                            // to its neighbours' (smaller) glyphs to grow into.
                            .padding(.horizontal, -9)
                            .padding(.vertical, -5)
                            .matchedGeometryEffect(id: "activeLetterBubble", in: bubbleNamespace)
                    }
                }
                // Fade with distance from the active letter (brightest at the
                // "cursor", dimmer further out) but never below a legible floor.
                .opacity(opacity(forMagnification: magnification))
                .zIndex(isActive ? 1 : 0)
                .focused($focus, equals: entry.letter)
            }
        }
        .padding(.vertical, PlozzTheme.Spacing.small)
        // Sit in the grid's trailing gutter (it hugs the safe-area edge, which is
        // already inset from the bezel by overscan) rather than pushing content.
        // Wide enough to give the enlarged active bubble room without clipping.
        .frame(width: 64)
        // Morph + magnify the letters between slots as the active letter changes —
        // whether that's the focused rail letter or the top-of-grid position marker.
        // A gentle spring makes the dock-style ripple feel slick rather than abrupt.
        // While the rail isn't focused (it's just tracking a manual grid scroll) use
        // a shorter spring so rapid multi-row jumps don't stack several long,
        // overlapping frame-reflow animations that fight the scroll for the main
        // thread; the flying-the-rail interaction keeps the fuller, slicker spring.
        .animation(focus != nil ? .smooth(duration: 0.32) : .smooth(duration: 0.2), value: currentLetter)
        .animation(.snappy(duration: 0.26, extraBounce: 0.12), value: focus)
        .focusSection()
        // Publish which letter is focused up to the parent (drives the jumbo
        // bubble + highlight), and fly the grid to it as focus arrives.
        .onChange(of: focus) { _, newValue in
            focusedLetter = newValue
            guard let newValue,
                  let entry = entries.first(where: { $0.letter == newValue }) else { return }
            onScrollToLetter(entry)
        }
    }

    /// Index of the currently-active letter (focused rail letter, or the top-of-grid
    /// position marker), used as the "cursor" the dock-style magnification centres on.
    private var activeIndex: Int? {
        guard let currentLetter else { return nil }
        return entries.firstIndex { $0.letter == currentLetter }
    }

    /// Resting scale of the letters far from the cursor. Below 1 so the inactive
    /// alphabet reads as a quiet, compact index and the active letter stands out.
    private let railBase: CGFloat = 0.8

    /// Extra scale added at the cursor on top of `railBase`. Larger while the rail
    /// itself is focused (you're actively flying letters) than when the active
    /// letter is merely marking the top-of-grid scroll position.
    private var railPeak: CGFloat { focus != nil ? 1.3 : 0.9 }

    /// macOS-Dock-style proximity magnification: the active letter is largest and
    /// the effect tapers off smoothly over a few neighbours on each side, which
    /// also pushes those neighbours outward (via their reflowed frame heights).
    private func magnification(forRowAt index: Int, activeIndex: Int?) -> CGFloat {
        guard let activeIndex else { return railBase }
        let spread = 3.5
        let distance = Double(abs(index - activeIndex))
        guard distance <= spread else { return railBase }
        let t = 1 - distance / spread
        let eased = t * t * (3 - 2 * t) // smoothstep for a soft dock falloff
        return railBase + railPeak * CGFloat(eased)
    }

    /// Brightest at the cursor, dimming with distance, but never below a legible
    /// floor so the whole alphabet stays readable on every theme.
    private func opacity(forMagnification magnification: CGFloat) -> Double {
        guard railPeak > 0 else { return 1 }
        let t = min(1, max(0, Double((magnification - railBase) / railPeak)))
        return 0.55 + 0.45 * t
    }
}

/// Focus/selection styling for a single rail letter: a compact glyph that lifts
/// Focus/selection styling for a single rail letter. The glyph scales with the
/// dock-style `magnification` (visually via `scaleEffect` for a smooth zoom, while
/// its reserved frame height grows by the same factor so neighbouring letters
/// reflow outward — the Dock "push" — rather than overlapping).
private struct LetterRailButtonStyle: ButtonStyle {
    let isCurrent: Bool
    let magnification: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        RailLetterBody(configuration: configuration, isCurrent: isCurrent, magnification: magnification)
    }

    private struct RailLetterBody: View {
        let configuration: ButtonStyle.Configuration
        let isCurrent: Bool
        let magnification: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.themePalette) private var palette

        private var foreground: Color {
            if isFocused || isCurrent { return palette.primaryText }
            return palette.secondaryText
        }

        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: isFocused || isCurrent ? .heavy : .bold))
                .foregroundStyle(foreground)
                // Scale the glyph itself (smooth) but reserve the magnified height so
                // the stack reflows and neighbours slide away, like the macOS Dock.
                .scaleEffect(magnification)
                .frame(width: 56, height: 37 * magnification)
        }
    }
}

/// The single liquid-glass pill that sits behind the rail's active letter and
/// slides between letters via `matchedGeometryEffect`. Plain neutral Liquid Glass
/// (native on tvOS 26+, a translucent material below that, a solid fill under
/// Reduce Transparency) — no tint or border, so it stays clean over any artwork.
private struct LetterRailBubble: View {
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.themePalette) private var palette

    var body: some View {
        let shape = Capsule(style: .continuous)
        backing(shape)
            .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
    }

    @ViewBuilder
    private func backing(_ shape: Capsule) -> some View {
        if reduceTransparency {
            shape.fill(palette.cardSurface)
        } else if #available(tvOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

/// The large, centered letter shown briefly while the rail is focused, echoing
/// Infuse's jumbo jump indicator so the target letter is readable at a glance.
private struct LetterJumpBubble: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(.system(size: 140, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 220, height: 220)
            .background(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(.black.opacity(0.55))
            )
            .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
    }
}

#if canImport(UIKit)
/// Probe that reaches its enclosing `UIScrollView`(s) and keeps the vertical
/// scroll indicator hidden. `.scrollIndicators(.never)` and a one-shot
/// `showsVerticalScrollIndicator = false` both proved unreliable on tvOS for this
/// grid: SwiftUI re-asserts the indicator after every layout pass, and — crucially
/// — tvOS's focus scroll bar (`_TVScrollBarView`) is a *dynamically re-created*
/// subview that reappears on focus-driven scrolls, so hiding it once (or only on a
/// `contentOffset` tick) misses the freshly-spawned instance. (Confirmed via
/// research: tvOS `ScrollView` is a real `UIScrollView`; SwiftUI overrides
/// introspected indicator properties; the tvOS bar is recreated on demand.)
///
/// Reliable fix: while hidden, drive a `CADisplayLink` that every frame walks the
/// enclosing scroll view(s) and re-hides both the property and any indicator
/// subview (`_UIScrollViewScrollIndicator` / `_TVScrollBarView`), catching the
/// re-created bar the instant it appears. The link runs only while the rail is up;
/// when the rail hides (non-name sort / scrolled to top) it stops and restores the
/// default indicator. Applies to every scroll view in the ancestor chain in case
/// the indicator lives on an outer `_UIHostingScrollView` rather than an inner one.
private struct ScrollIndicatorHider: UIViewControllerRepresentable {
    var hidden: Bool

    func makeUIViewController(context: Context) -> ScrollIndicatorHiderController {
        let controller = ScrollIndicatorHiderController()
        controller.hidden = hidden
        return controller
    }

    func updateUIViewController(_ controller: ScrollIndicatorHiderController, context: Context) {
        controller.hidden = hidden
    }

    static func dismantleUIViewController(_ controller: ScrollIndicatorHiderController, coordinator: ()) {
        // Guarantee the display link stops (breaking its strong retain on the
        // controller) the instant SwiftUI removes this probe, without relying on a
        // `didMove(toParent:)` callback firing during teardown.
        controller.teardown()
    }
}

private final class ScrollIndicatorHiderController: UIViewController {
    var hidden: Bool = false {
        didSet { if hidden != oldValue { syncDisplayLink() } }
    }
    private var scrollViews: [UIScrollView] = []
    private var displayLink: CADisplayLink?
    /// Once we've located the tvOS index bar we cache its (private) class and the
    /// view that hosts it. tvOS *re-creates* the bar on focus-driven scrolls, so we
    /// can't just blank one instance — but every re-created bar is the same class
    /// re-added to the same host, so each frame we only re-blank that host's
    /// matching children (a fast `isKind(of:)` check), never re-walking the tree.
    private var indexBarClass: AnyClass?
    private weak var indexBarHost: UIView?
    /// Throttles the (rare) full view-tree walk used to first discover the bar, so
    /// that before it ever appears we aren't recursing the whole window every frame.
    private var framesUntilDiscover = 0
    private static let discoverInterval = 15
    /// Once the bar's class + host are cached, we re-run discovery only very
    /// occasionally — and only while idle (see `enforce()`) — purely to self-heal if
    /// tvOS ever re-creates the bar under a *different* host. This is the rare case;
    /// the common re-creation (same host) is caught for free by the per-frame
    /// re-blank, so this walk never needs to run during an active scroll.
    private static let revalidateInterval = 240

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { stopDisplayLink() } else { syncDisplayLink() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncDisplayLink()
    }

    /// Collect every `UIScrollView` in the ancestor chain (the tvOS bar can live on
    /// an outer hosting scroll view, not just the innermost one the walk first
    /// hits), so we can enforce on all of them.
    private func locateScrollViewsIfNeeded() {
        guard scrollViews.isEmpty else { return }
        var found: [UIScrollView] = []
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView { found.append(scrollView) }
            ancestor = current.superview
        }
        scrollViews = found
    }

    private func syncDisplayLink() {
        guard isViewLoaded, view.window != nil || parent != nil else { return }
        if hidden {
            locateScrollViewsIfNeeded()
            enforce()
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            stopDisplayLink()
            enforce()
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Stop the display link and restore the native indicators. Invoked from the
    /// representable's `dismantleUIViewController` so cleanup is deterministic on
    /// SwiftUI teardown (a `CADisplayLink` retains its target, so `deinit` alone is
    /// not a reliable fallback if the parent callback is skipped).
    func teardown() {
        hidden = false
        stopDisplayLink()
    }

    @objc private func tick() {
        enforce()
    }

    /// Show or hide the tvOS fast-scrolling index bar. This is the private
    /// `_UIFocusFastScrollingIndexBarView` — a trailing-edge bar tvOS auto-adds to
    /// long focusable scroll views, rendered as a column of collapsed section-index
    /// marks (the "dots") plus a `_UIFocusFastScrollingIndexBarIndicatorView`
    /// circular thumb. It is NOT the ordinary scroll indicator, so
    /// `showsVerticalScrollIndicator` / indicator-inset tricks never touched it.
    ///
    /// Crucially we must NOT hide the bar container itself: on tvOS the bar
    /// participates in the fast-scroll interaction, so hiding the container
    /// mid-scroll cancels the gesture and stalls scrolling. Instead we blank only
    /// its visible leaf subviews (the dot labels + the thumb) via alpha, leaving the
    /// container fully present and interactive. tvOS re-creates the bar on
    /// focus-driven scrolls, so once we've learned its class + host view we simply
    /// re-blank the host's matching children every frame — an `isKind(of:)` check
    /// over a handful of siblings, not a walk of the whole view tree.
    private func enforce() {
        // Nothing to do while we're off-screen (e.g. covered by a pushed
        // destination): skip the scroll-view scan and any discovery walk so the
        // display link, if it's still ticking, costs effectively nothing until we
        // return to the window.
        guard isViewLoaded, view.window != nil else { return }
        if scrollViews.isEmpty { locateScrollViewsIfNeeded() }
        let shouldHide = hidden
        for scrollView in scrollViews where scrollView.showsVerticalScrollIndicator == shouldHide {
            scrollView.showsVerticalScrollIndicator = !shouldHide
        }
        // A cached host that has left the window is stale — drop it so discovery
        // re-runs against the live hierarchy on the next tick.
        if let host = indexBarHost, host.window == nil {
            indexBarClass = nil
            indexBarHost = nil
        }
        // Learn the bar's class + host, then re-blank that host's matching children
        // each frame. Discovery is throttled quickly while the bar hasn't been found
        // yet; once cached, the only remaining re-discovery is a rare cross-host
        // self-heal, which we defer until the scroll settles — a full-window walk
        // mid-scroll drops frames and is the main source of scroll choppiness. The
        // common re-creation (same host) is caught for free by the per-frame
        // re-blank below, and a host leaving the window is dropped above.
        if framesUntilDiscover > 0 { framesUntilDiscover -= 1 }
        if framesUntilDiscover == 0 {
            let cached = indexBarClass != nil && indexBarHost != nil
            if cached {
                framesUntilDiscover = Self.revalidateInterval
                if !isScrolling { discoverIndexBar() }
            } else {
                framesUntilDiscover = Self.discoverInterval
                discoverIndexBar()
            }
        }
        guard let host = indexBarHost, let barClass = indexBarClass else { return }
        let targetAlpha: CGFloat = shouldHide ? 0 : 1
        for subview in host.subviews where subview.isKind(of: barClass) {
            for element in subview.subviews where element.alpha != targetAlpha {
                element.alpha = targetAlpha
            }
        }
    }

    /// True while any tracked scroll view is being dragged or is coasting, used to
    /// keep the (rare, expensive) full-window re-discovery walk off the main thread
    /// during an active scroll so it can't drop frames.
    private var isScrolling: Bool {
        scrollViews.contains { $0.isDragging || $0.isTracking || $0.isDecelerating }
    }

    /// One-off recursive walk (from the window, falling back to the scroll views) to
    /// find the index bar and cache its class + host. Matched by class-name
    /// substring so there are no private symbols at compile time; degrades
    /// gracefully (bar simply stays visible) if tvOS ever renames the view.
    private func discoverIndexBar() {
        let roots: [UIView] = ([view.window].compactMap { $0 }) + scrollViews
        for root in roots {
            if let bar = firstIndexBarView(in: root) {
                indexBarClass = type(of: bar)
                indexBarHost = bar.superview
                return
            }
        }
    }

    private func firstIndexBarView(in view: UIView) -> UIView? {
        for subview in view.subviews {
            if String(describing: type(of: subview)).contains("FastScrollingIndexBarView") {
                return subview
            }
            if let found = firstIndexBarView(in: subview) { return found }
        }
        return nil
    }

    deinit { stopDisplayLink() }
}
#endif

#endif
