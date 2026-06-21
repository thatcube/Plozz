#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// A sparse, lazily-loaded poster grid for browsing a single library, styled to
/// match the Twozz "Browse" grid (liquid-glass tiles, dense ~7-across layout,
/// focus lift).
///
/// After the first page loads (which reports the library's total size), the grid
/// is laid out for the *entire* library at once: every slot renders a tile, and
/// each tile lazily triggers loading of the page it belongs to as it scrolls
/// into view. Not-yet-loaded slots show a placeholder until their page arrives,
/// so even libraries with thousands of items scroll smoothly and never block on
/// a single all-items request.
public struct LibraryBrowseView: View {
    @State private var viewModel: LibraryBrowseViewModel
    @FocusState private var focusedID: String?
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

    // Fixed 7-column layout to match the Twozz "Browse" grid density.
    private static let columnCount = 7
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: PlozzTheme.Metrics.gridSpacing),
        count: LibraryBrowseView.columnCount
    )

    public var body: some View {
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
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                .padding(.vertical, 40)
                .focusSection()
            }
        }
        .navigationTitle(title)
        .task { if viewModel.state.value == nil { await viewModel.loadFirstPage() } }
    }

    @ViewBuilder
    private func cell(at index: Int) -> some View {
        let item = viewModel.item(at: index)
        let isFocused = item != nil && focusedID == item?.id

        LibraryTileView(item: item, isFocused: isFocused, spoilerSettings: spoilerSettings)
            .modifier(FocusableTile(
                id: item?.id,
                isFocused: isFocused,
                focusedID: $focusedID,
                onSelect: { if let item { onSelect(item) } }
            ))
            .onAppear { Task { await viewModel.itemAppeared(at: index) } }
    }
}

/// Adds tvOS focus, tap-to-select and a focus "lift" to loaded tiles only;
/// placeholders (nil id) stay inert so focus skips over them.
private struct FocusableTile: ViewModifier {
    let id: String?
    let isFocused: Bool
    var focusedID: FocusState<String?>.Binding
    let onSelect: () -> Void

    func body(content: Content) -> some View {
        if let id {
            content
                .contentShape(RoundedRectangle(cornerRadius: LibraryTileView.outerCornerRadius, style: .continuous))
                .focusable(true)
                .focused(focusedID, equals: id)
                .focusEffectDisabled()
                .onTapGesture(perform: onSelect)
                .scaleEffect(isFocused ? PlozzTheme.Metrics.focusedCardScale : 1)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .zIndex(isFocused ? 2 : 0)
        } else {
            content
        }
    }
}

/// A single grid cell styled like a Twozz Browse card: liquid-glass surface,
/// rounded box art, semibold title and a secondary line. Renders a redacted
/// placeholder while its owning page is still loading.
private struct LibraryTileView: View {
    let item: MediaItem?
    let isFocused: Bool
    let spoilerSettings: SpoilerSettings

    static let outerCornerRadius: CGFloat = 30
    private let artCornerRadius: CGFloat = 18
    private let artRatio: CGFloat = 2.0 / 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            art
                .aspectRatio(artRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: artCornerRadius, style: .continuous))
                .overlay(alignment: .bottom) { progressBar }

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.8)
                Text(secondaryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .opacity(item?.subtitle == nil ? 0 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .padding(10)
        .plozzGlassCard(cornerRadius: Self.outerCornerRadius, isFocused: isFocused)
        .redacted(reason: item == nil ? .placeholder : [])
    }

    private var primaryText: String {
        guard let item else { return "Loading" }
        return spoilerSettings.shouldHideText(for: item) ? spoilerSettings.maskedTitle(for: item) : item.title
    }

    private var secondaryText: String { item?.subtitle ?? " " }

    @ViewBuilder
    private var art: some View {
        if let item {
            if spoilerSettings.shouldHideThumbnail(for: item) {
                switch spoilerSettings.mode {
                case .blur:
                    realArtwork(for: item).blur(radius: 24).overlay { spoilerBadge }
                case .placeholder:
                    fallbackArtwork(icon: "eye.slash.fill")
                }
            } else {
                realArtwork(for: item)
            }
        } else {
            fallbackArtwork(icon: "photo")
        }
    }

    @ViewBuilder
    private func realArtwork(for item: MediaItem) -> some View {
        AsyncImage(url: item.posterURL) { phase in
            switch phase {
            case let .success(image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                fallbackArtwork(icon: "film")
            case .empty:
                fallbackArtwork(icon: "photo")
            @unknown default:
                fallbackArtwork(icon: "photo")
            }
        }
    }

    private func fallbackArtwork(icon: String) -> some View {
        ZStack {
            Rectangle().fill(.tertiary)
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
        }
    }

    private var spoilerBadge: some View {
        Image(systemName: "eye.slash.fill")
            .font(.system(size: 22))
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.5), in: Circle())
    }

    @ViewBuilder
    private var progressBar: some View {
        if let item, let percentage = item.playedPercentage, percentage > 0.01, percentage < 0.99 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.4))
                    Rectangle().fill(.tint).frame(width: geo.size.width * percentage)
                }
            }
            .frame(height: 6)
        }
    }
}

#endif
