#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The shared "reorder and hide" list control: one ordered list split by a
/// **Disabled** divider, where moving a row across the divider is what turns it
/// off. Backed by the app-wide ``OrderedVisibilityList`` model, so every surface
/// that lets the viewer reorder-and-hide a collection (metadata providers, the
/// navigation libraries, …) is the same control with the same muscle memory.
///
/// **tvOS interaction** — the whole row is the focus target (no per-row buttons):
/// click to *lift* it, then d-pad Up/Down moves it one step as focus follows
/// (crossing the divider enables/disables), and click again to drop it. Neighbours
/// dim while a row is lifted, which is the tvOS Home-screen rearrange idiom.
///
/// **iOS/iPadOS interaction** — the native always-editing `List` drag handle over
/// the same flattened model, with the divider immovable.
public struct LiftableReorderList<Element: Hashable>: View {
    /// What one row shows. Kept as a small value (rather than a `@ViewBuilder`) so
    /// the row chrome — focus card, rank, handle, dim/lift treatment — is owned
    /// here and can never drift between the surfaces that use this control.
    public struct Row {
        public var title: Text
        /// Optional leading SF Symbol, e.g. a library's content-kind glyph.
        public var symbolName: String?
        /// Optional trailing detail line, e.g. the server a library came from.
        public var detail: Text?

        public init(title: Text, symbolName: String? = nil, detail: Text? = nil) {
            self.title = title
            self.symbolName = symbolName
            self.detail = detail
        }
    }

    private let sections: OrderedVisibilityList.Sections<Element>
    private let row: (Element) -> Row
    private let disabledSectionTitle: LocalizedStringResource
    private let disabledPlaceholder: LocalizedStringResource
    /// Mirrors "a row is currently lifted" outward so the host page can disable its
    /// other controls while a reorder is in progress.
    @Binding private var isLifting: Bool
    private let onChange: (OrderedVisibilityList.Sections<Element>) -> Void

    /// The element currently "lifted" for reordering (nil = none lifted).
    @State private var liftedElement: Element?
    @State private var isRestoringLiftedFocus = false
    @FocusState private var focusedElement: Element?
    @FocusState private var isDisabledPlaceholderFocused: Bool

    public init(
        sections: OrderedVisibilityList.Sections<Element>,
        disabledSectionTitle: LocalizedStringResource,
        disabledPlaceholder: LocalizedStringResource,
        isLifting: Binding<Bool>,
        row: @escaping (Element) -> Row,
        onChange: @escaping (OrderedVisibilityList.Sections<Element>) -> Void
    ) {
        self.sections = sections
        self.disabledSectionTitle = disabledSectionTitle
        self.disabledPlaceholder = disabledPlaceholder
        self._isLifting = isLifting
        self.row = row
        self.onChange = onChange
    }

    #if os(tvOS)
    public var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(sections.enabled.enumerated()), id: \.element) { index, element in
                rowView(element, isEnabled: true, rank: index + 1)
            }

            ReorderDisabledDivider(
                title: disabledSectionTitle,
                isDropTarget: liftedElement != nil
            )

            if sections.disabled.isEmpty {
                ReorderDisabledPlaceholder(
                    message: disabledPlaceholder,
                    isReordering: liftedElement != nil
                )
                .focused($isDisabledPlaceholderFocused)
                .onChange(of: isDisabledPlaceholderFocused) { _, isFocused in
                    handleEmptyDisabledDropTargetFocus(isFocused)
                }
            } else {
                ForEach(sections.disabled, id: \.self) { element in
                    rowView(element, isEnabled: false, rank: nil)
                }
            }
        }
        // Reorder rides the native focus move: while a row is lifted, moving focus
        // to a neighbour becomes a one-step move.
        .onChange(of: focusedElement) { _, newValue in
            handleFocusMoveWhileLifted(to: newValue)
        }
        .onChange(of: liftedElement) { _, lifted in
            isLifting = lifted != nil
        }
        .onDisappear { isLifting = false }
    }

    private func rowView(_ element: Element, isEnabled: Bool, rank: Int?) -> some View {
        let lifting = liftedElement != nil
        let content = row(element)
        return LiftableRow(
            title: content.title,
            detail: content.detail,
            symbolName: content.symbolName,
            isEnabled: isEnabled,
            isLifted: liftedElement == element,
            isDimmed: lifting && liftedElement != element,
            rank: rank,
            onPrimary: { toggleLift(element) }
        )
        .focused($focusedElement, equals: element)
    }

    /// Click handler: lift the focused row, or drop it if it's already lifted.
    private func toggleLift(_ element: Element) {
        withAnimation(.snappy(duration: 0.16)) {
            liftedElement = (liftedElement == element) ? nil : element
        }
    }

    /// When a row is lifted and focus moves to a different row (a d-pad press),
    /// reorder the lifted row one step toward that row. Focus is restored on the
    /// next layout pass: restoring it synchronously targets the row's old frame and
    /// can make a subsequent Down press appear to move upward.
    private func handleFocusMoveWhileLifted(to newValue: Element?) {
        guard !isRestoringLiftedFocus,
              let lifted = liftedElement,
              let target = newValue,
              target != lifted else { return }
        let combined = sections.combined
        guard let from = combined.firstIndex(of: lifted),
              let to = combined.firstIndex(of: target) else { return }
        let up = to < from
        let next = OrderedVisibilityList.stepped(lifted, up: up, in: sections)
        guard next != sections else {
            restoreFocusAfterLayout(to: lifted)
            return
        }
        isRestoringLiftedFocus = true
        withAnimation(.easeOut(duration: 0.10)) {
            onChange(next)
        }
        restoreFocusAfterLayout(to: lifted)
    }

    /// The dashed empty-disabled row is a real focus target. Landing on it while a
    /// row is lifted means "move across the divider": disable the element, then keep
    /// focus on that same element in its new disabled position.
    private func handleEmptyDisabledDropTargetFocus(_ isFocused: Bool) {
        guard isFocused,
              !isRestoringLiftedFocus,
              let lifted = liftedElement else { return }
        let next = OrderedVisibilityList.stepped(lifted, up: false, in: sections)
        guard next != sections else { return }
        isRestoringLiftedFocus = true
        withAnimation(.easeOut(duration: 0.10)) {
            onChange(next)
        }
        restoreFocusAfterLayout(to: lifted)
    }

    /// Wait one run-loop turn for the reordered `ForEach` frames to settle before
    /// asking the focus engine to follow the lifted row to its new slot.
    private func restoreFocusAfterLayout(to element: Element) {
        Task { @MainActor in
            await Task.yield()
            isDisabledPlaceholderFocused = false
            focusedElement = element
            isRestoringLiftedFocus = false
        }
    }
    #else
    public var body: some View {
        let items = OrderedVisibilityList.listItems(for: sections)
        return List {
            ForEach(items, id: \.self) { item in
                listRow(item)
                    .moveDisabled(item == .divider)
            }
            .onMove { offsets, destination in
                onChange(
                    OrderedVisibilityList.moving(
                        fromOffsets: offsets,
                        toOffset: destination,
                        in: sections
                    )
                )
            }
        }
        .listStyle(.plain)
        .scrollDisabled(true)
        .environment(\.editMode, .constant(.active))
        .frame(height: CGFloat(items.count) * 54)
    }

    @ViewBuilder
    private func listRow(_ item: OrderedVisibilityList.ListItem<Element>) -> some View {
        switch item {
        case let .element(element):
            let content = row(element)
            let isEnabled = sections.enabled.contains(element)
            HStack {
                if let index = sections.enabled.firstIndex(of: element) {
                    Text(index + 1, format: .number)
                        .font(.caption.monospacedDigit())
                        .plozzForeground(.secondary)
                }
                if let symbolName = content.symbolName {
                    Image(systemName: symbolName)
                        .font(.callout)
                        .accessibilityHidden(true)
                }
                content.title
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                if let detail = content.detail {
                    Spacer(minLength: 8)
                    detail
                        .font(.caption)
                        .plozzForeground(.secondary)
                }
            }
        case .divider:
            Text(disabledSectionTitle)
                .font(.caption.weight(.semibold))
                .plozzForeground(.secondary)
                .textCase(.uppercase)
        case .disabledPlaceholder:
            Text(disabledPlaceholder)
                .font(.caption)
                .plozzForeground(.secondary)
        }
    }
    #endif
}

/// One focusable row in the ordered list. The **whole row** is the focus target.
/// An always-visible reorder handle sits on the trailing edge.
private struct LiftableRow: View {
    let title: Text
    let detail: Text?
    let symbolName: String?
    let isEnabled: Bool
    let isLifted: Bool
    let isDimmed: Bool
    /// 1-based priority rank when enabled; `nil` when disabled.
    let rank: Int?
    let onPrimary: () -> Void

    var body: some View {
        Button(action: onPrimary) {
            HStack(spacing: 14) {
                if let rank {
                    Text(rank, format: .number)
                        .font(.callout.weight(.bold).monospacedDigit())
                        .frame(minWidth: 26, alignment: .trailing)
                }
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.headline)
                        .frame(minWidth: 30)
                        .accessibilityHidden(true)
                }
                title
                    .font(.headline.weight(.semibold))
                if let detail {
                    detail
                        .font(.caption)
                        .opacity(0.7)
                }
                Spacer(minLength: 12)
                Image(systemName: "line.3.horizontal")
                    .font(.title3)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            LiftableRowButtonStyle(
                isEnabled: isEnabled,
                isLifted: isLifted,
                suppressFocusAppearance: isDimmed
            )
        )
        .opacity(isDimmed ? 0.4 : 1)
        .scaleEffect(isLifted ? 1.04 : 1)
        .shadow(color: .black.opacity(isLifted ? 0.5 : 0), radius: isLifted ? 18 : 0, y: isLifted ? 9 : 0)
        .zIndex(isLifted ? 1 : 0)
    }
}

/// Row chrome using ONLY the existing Settings design language — no new colors. A
/// lifted (grabbed) or focused row both render as the standard tvOS inverted card
/// (white fill / black text in dark mode); "grabbed" is distinguished by the row's
/// scale + shadow and its dimmed neighbors (the tvOS Home-screen rearrange idiom),
/// not a tint. Foreground is set here so it always matches the fill.
private struct LiftableRowButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let isLifted: Bool
    /// During reordering, native focus briefly visits the adjacent row to
    /// communicate direction. Hide that row's focus card so only the lifted row
    /// ever highlights.
    let suppressFocusAppearance: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let inverted = isLifted || (isFocused && !suppressFocusAppearance)
        let invertedFill: Color = colorScheme == .dark ? .white : .black
        let invertedText: Color = colorScheme == .dark ? .black : .white

        let foreground: AnyShapeStyle = inverted
            ? AnyShapeStyle(invertedText)
            : (isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        let fill: AnyShapeStyle = inverted ? AnyShapeStyle(invertedFill) : AnyShapeStyle(Color.clear)

        return configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
            )
    }
}

/// The divider that separates enabled (above) from disabled (below).
private struct ReorderDisabledDivider: View {
    let title: LocalizedStringResource
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .plozzForeground(.secondary)
                .textCase(.uppercase)
            Rectangle()
                .fill(Color.secondary.opacity(isDropTarget ? 0.6 : 0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}

/// Shown in the disabled area when nothing is disabled, so the disable target stays
/// discoverable: a lifted row moved down here becomes disabled.
private struct ReorderDisabledPlaceholder: View {
    let message: LocalizedStringResource
    let isReordering: Bool

    var body: some View {
        Button(action: {}) {
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
        }
        .buttonStyle(
            ReorderPlaceholderButtonStyle(suppressFocusAppearance: isReordering)
        )
    }
}

private struct ReorderPlaceholderButtonStyle: ButtonStyle {
    let suppressFocusAppearance: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let inverted = isFocused && !suppressFocusAppearance
        let invertedFill: Color = colorScheme == .dark ? .white : .black
        let invertedText: Color = colorScheme == .dark ? .black : .white
        return configuration.label
            .foregroundStyle(inverted ? AnyShapeStyle(invertedText) : AnyShapeStyle(.secondary))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(inverted ? AnyShapeStyle(invertedFill) : AnyShapeStyle(Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                    )
                    .foregroundStyle(.secondary.opacity(inverted ? 0 : 0.5))
            )
    }
}
#endif
