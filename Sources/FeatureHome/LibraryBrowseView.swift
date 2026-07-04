#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

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
    @State private var prefetchedArtworkItemIDs: Set<String> = []
    /// The rail letter that currently holds focus, or `nil` when focus is in the
    /// grid. Drives the fly-through highlight + the transient jumbo letter bubble.
    @State private var railFocusedLetter: String?
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
                        #if canImport(UIKit)
                        // `.scrollIndicators(.never)` does NOT stick on tvOS for
                        // this grid — the system still flashes the dotted indicator
                        // on top of the alphabet rail. So we reach the enclosing
                        // UIScrollView directly and toggle its vertical indicator,
                        // hiding it only while the rail is up (name sort) and
                        // restoring it for every other sort. The probe is a real
                        // child of the scroll content so its superview walk lands
                        // on the UIScrollView (mirrors HomeView's ScrollPanDisabler).
                        ScrollIndicatorHider(hidden: viewModel.showsLetterRail)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        #endif
                        header
                        LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
                            ForEach(0..<total, id: \.self) { index in
                                cell(at: index)
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
                }
                // Never clip a focused card's lift, shadow or border.
                .scrollClipDisabled()
                .overlay(alignment: .trailing) {
                    if viewModel.showsLetterRail {
                        LibraryLetterRail(
                            entries: viewModel.letterEntries,
                            currentLetter: currentLetter,
                            focusedLetter: $railFocusedLetter,
                            onScrollToLetter: { entry in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(entry.startIndex, anchor: .top)
                                }
                            }
                        )
                        // Nudge the rail into the trailing gutter (where the native
                        // scroll indicator used to sit) so it clears the poster
                        // wall instead of hugging the last column.
                        .offset(x: 22)
                    }
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
            }
        }
        // Browse is a full-screen sub-page: hide the top tab bar so it reads as a
        // dedicated destination with no navigation chrome pinned at the top.
        .toolbar(.hidden, for: .tabBar)
        .task { if viewModel.state.value == nil { await viewModel.loadFirstPage() } }
    }

    /// The letter to highlight as "current": the focused rail letter while flying
    /// the rail, otherwise the letter owning the top-most visible grid row.
    private var currentLetter: String? {
        if let railFocusedLetter { return railFocusedLetter }
        return viewModel.letter(forIndex: viewModel.topVisibleIndex ?? 0)
    }

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
                Task { await viewModel.setSort(CoreModels.SortDescriptor(field: field, direction: viewModel.sort.direction)) }
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

    @ViewBuilder
    private func cell(at index: Int) -> some View {
        Group {
            if let item = viewModel.item(at: index) {
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
        .task(id: index) {
            await viewModel.itemAppeared(at: index)
            prefetchArtwork(aheadFrom: index)
        }
        .onDisappear { viewModel.itemDisappeared(at: index) }
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
            guard !prefetchedArtworkItemIDs.contains(candidate.id) else { continue }
            prefetchedArtworkItemIDs.insert(candidate.id)
            for url in candidate.artworkCandidates(for: .poster).prefix(2) {
                ArtworkImageCache.shared.prefetch(url, variant: .posterCard)
            }
        }
        #endif
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

/// The Infuse-style vertical A–Z fast-scroll rail pinned to the trailing edge of
/// the browse grid. Each present letter is a focusable button; moving focus onto
/// a letter scrolls the grid to that letter's first item (fly-through), and
/// pressing it jumps there too. The letter whose range currently sits at the top
/// of the grid is highlighted so it doubles as a position indicator.
///
/// Only shown when the grid is name-sorted (the view model supplies the per-letter
/// offsets), so it never appears for date/rating/etc. sorts where letters are
/// meaningless.
private struct LibraryLetterRail: View {
    let entries: [LibraryLetterIndexEntry]
    let currentLetter: String?
    @Binding var focusedLetter: String?
    let onScrollToLetter: (LibraryLetterIndexEntry) -> Void

    @FocusState private var focus: String?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(entries, id: \.letter) { entry in
                Button {
                    onScrollToLetter(entry)
                } label: {
                    Text(entry.letter)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    LetterRailButtonStyle(isCurrent: entry.letter == currentLetter)
                )
                .focused($focus, equals: entry.letter)
            }
        }
        .padding(.vertical, PlozzTheme.Spacing.medium)
        // Sit in the grid's trailing gutter (it hugs the safe-area edge, which is
        // already inset from the bezel by overscan) rather than pushing content.
        .frame(width: 40)
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
}

/// Focus/selection styling for a single rail letter: a compact glyph that lifts
/// into the standard bright tvOS focus pill when focused, and tints to the brand
/// accent (without a pill) when it is merely the current position marker.
private struct LetterRailButtonStyle: ButtonStyle {
    let isCurrent: Bool

    func makeBody(configuration: Configuration) -> some View {
        RailLetterBody(configuration: configuration, isCurrent: isCurrent)
    }

    private struct RailLetterBody: View {
        let configuration: ButtonStyle.Configuration
        let isCurrent: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.themePalette) private var palette

        private var foreground: Color {
            if isFocused { return .black }
            if isCurrent { return palette.accent }
            return palette.secondaryText
        }

        var body: some View {
            configuration.label
                .font(.system(size: 20, weight: isFocused || isCurrent ? .bold : .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .frame(width: 34, height: 30)
                .background(
                    Circle()
                        .fill(.white)
                        .opacity(isFocused ? 1 : 0)
                )
                .scaleEffect(isFocused ? 1.2 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isFocused)
                .animation(.easeOut(duration: 0.14), value: isCurrent)
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
/// Probe that reaches its enclosing `UIScrollView` and toggles the vertical
/// scroll indicator directly. SwiftUI's `.scrollIndicators(.never)` proved
/// unreliable on tvOS for the browse grid (the system kept flashing the dotted
/// indicator on top of the alphabet rail), so we set
/// `showsVerticalScrollIndicator` ourselves. Modeled on `HomeView`'s
/// `ScrollPanDisabler`: a `UIViewController` re-asserts on every layout pass so
/// SwiftUI can't quietly re-enable the indicator, and it flips back on when the
/// rail is hidden (non-name sorts) so those keep the default indicator.
private struct ScrollIndicatorHider: UIViewControllerRepresentable {
    var hidden: Bool

    func makeUIViewController(context: Context) -> ScrollIndicatorHiderController {
        let controller = ScrollIndicatorHiderController()
        controller.hidden = hidden
        return controller
    }

    func updateUIViewController(_ controller: ScrollIndicatorHiderController, context: Context) {
        controller.hidden = hidden
        controller.reapply()
    }
}

private final class ScrollIndicatorHiderController: UIViewController {
    var hidden: Bool = false
    private weak var scrollView: UIScrollView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reapply()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        reapply()
    }

    func reapply() {
        if let scrollView {
            scrollView.showsVerticalScrollIndicator = !hidden
            return
        }
        var ancestor = view.superview
        while let current = ancestor {
            if let found = current as? UIScrollView {
                scrollView = found
                found.showsVerticalScrollIndicator = !hidden
                return
            }
            ancestor = current.superview
        }
    }
}
#endif

#endif
