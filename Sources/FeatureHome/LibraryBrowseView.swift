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
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
                    header
                    LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
                        ForEach(0..<total, id: \.self) { index in
                            cell(at: index)
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
        }
        // Browse is a full-screen sub-page: hide the top tab bar so it reads as a
        // dedicated destination with no navigation chrome pinned at the top.
        .toolbar(.hidden, for: .tabBar)
        .task { if viewModel.state.value == nil { await viewModel.loadFirstPage() } }
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

#endif
