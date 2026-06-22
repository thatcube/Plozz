#if canImport(SwiftUI)
import SwiftUI

/// A horizontally-scrolling row of selectable "cards" — one tile per option,
/// laid out side-by-side instead of stacked in a vertical `Picker`.
///
/// This is the building block of the Twozz-style settings look that Plozz
/// adopts: choices read as a row of focusable tiles in the 10-foot UI, the
/// current selection highlighted with the accent tint and a checkmark. It lives
/// in `CoreUI` so both the Settings screen and the in-player caption controls
/// can reuse it without duplicating the focus/selection styling.
public struct OptionCardRow<Option: Hashable, Label: View>: View {
    private let options: [Option]
    @Binding private var selection: Option
    private let label: (Option) -> Label

    public init(
        options: [Option],
        selection: Binding<Option>,
        @ViewBuilder label: @escaping (Option) -> Label
    ) {
        self.options = options
        self._selection = selection
        self.label = label
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(options, id: \.self) { option in
                    OptionCard(isSelected: selection == option) {
                        selection = option
                    } label: {
                        label(option)
                    }
                }
            }
            // Padding so a focused card's lift + shadow are never clipped by the
            // horizontal scroll view.
            .padding(.horizontal, 4)
            .padding(.vertical, 16)
        }
        // Never clip a focused card's lift, shadow or border.
        .scrollClipDisabled()
    }
}

/// A single focusable selectable tile used by `OptionCardRow`. Uses `.plain`
/// button styling so the tile owns its own focus appearance (scale + accent
/// border) rather than the default tvOS button chrome.
private struct OptionCard<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    @Environment(\.themePalette) private var palette
    @FocusState private var isFocused: Bool

    private let cornerRadius: CGFloat = 18

    var body: some View {
        Button(action: action) {
            label
                .frame(minWidth: 150, minHeight: 92)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(palette.accent)
                            .padding(10)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .plozzGlassCard(cornerRadius: cornerRadius, isFocused: isFocused)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? palette.accent : Color.clear,
                    lineWidth: isSelected ? 4 : 0
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isFocused ? palette.accent.opacity(0.9) : Color.clear,
                    lineWidth: isFocused ? 6 : 0
                )
        }
        .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 18, y: 10)
        .scaleEffect(isFocused ? 1.08 : 1)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

#endif
