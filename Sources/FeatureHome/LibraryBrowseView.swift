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
    private let title: String
    private let spoilerSettings: SpoilerSettings
    private let onSelect: (MediaItem) -> Void

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

    // Fixed-width columns sized to the shared poster card so Library uses the
    // exact same card as Home's "Recently Added" row, flowing as many columns as
    // fit the available width.
    private let columns = [
        GridItem(
            .adaptive(
                minimum: PlozzTheme.Metrics.posterWidth,
                maximum: PlozzTheme.Metrics.posterWidth
            ),
            spacing: PlozzTheme.Metrics.gridSpacing,
            alignment: .top
        )
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ContentStateView(
                state: viewModel.state,
                emptyMessage: "This library is empty.",
                onRetry: { Task { await viewModel.loadFirstPage() } }
            ) { total in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: PlozzTheme.Metrics.gridSpacing) {
                        ForEach(0..<total, id: \.self) { index in
                            cell(at: index)
                        }
                    }
                    .padding(.horizontal, HomeLayout.horizontalPadding)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                    .focusSection()
                }
            }
        }
        // Browse is a full-screen sub-page: hide the top tab bar so it reads as a
        // dedicated destination and the Sort control becomes the natural up-target.
        .toolbar(.hidden, for: .tabBar)
        .task { if viewModel.state.value == nil { await viewModel.loadFirstPage() } }
    }

    /// A pinned header (title + Sort) that never scrolls away. It lives in its own
    /// focus section above the grid, so the Sort menu is always reachable by
    /// pressing up from the top grid row — no scroll-to-top required.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.largeTitle.bold())
            Spacer(minLength: 24)
            sortControl
        }
        .padding(.horizontal, HomeLayout.horizontalPadding)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .focusSection()
    }

    /// A focusable sort menu shown in the pinned header.
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
        if let item = viewModel.item(at: index) {
            // Shared poster card — identical to Home's "Recently Added" row.
            PosterCardView(item: item, style: .poster, spoilerSettings: spoilerSettings) {
                onSelect(item)
            }
            .onAppear { Task { await viewModel.itemAppeared(at: index) } }
        } else {
            PosterPlaceholderView()
                .onAppear { Task { await viewModel.itemAppeared(at: index) } }
        }
    }
}

/// A poster-shaped, redacted placeholder for a not-yet-loaded grid slot. Sized to
/// match `PosterCardView`'s `.poster` artwork so columns stay aligned while a page
/// is in flight. Inert (non-focusable) so focus skips over it.
private struct PosterPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius)
                .fill(Color.primary.opacity(0.08))
                .frame(width: PlozzTheme.Metrics.posterWidth, height: PlozzTheme.Metrics.posterHeight)
            VStack(alignment: .leading, spacing: 2) {
                Text("Loading").font(.headline)
                Text(" ").font(.subheadline)
            }
            .frame(width: PlozzTheme.Metrics.posterWidth, alignment: .leading)
            .redacted(reason: .placeholder)
        }
    }
}

#endif
