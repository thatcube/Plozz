#if canImport(SwiftUI)
import SwiftUI

/// A horizontally-scrolling row of selectable "season tab" pills — one chip per
/// option, the current selection wearing the accent pill and a checkmark.
///
/// This extracts the label-pill idiom that the Settings screens repeated by hand
/// (Appearance's Theme/Display Size/Transparency pickers, Night Shift's
/// schedule and look pickers, …). Centralising it here keeps every settings
/// picker visually identical and focus-correct in the 10-foot UI, and lets new
/// screens drop in a picker with one initializer instead of copy-pasting a
/// `ScrollView` + `ForEach` + `PlozzSeasonTabStyle` block.
///
/// Pair it with ``LabeledSettingRow`` to get a compact one-line "label on the
/// left, pills on the right" settings row.
public struct SettingsOptionPicker<Option: Hashable>: View {
    private let options: [Option]
    @Binding private var selection: Option
    private let title: (Option) -> String
    private let icon: (Option) -> String?
    private let onFocusChange: ((Bool) -> Void)?

    /// Tracks which chip (if any) currently holds focus so the row can report
    /// "I am focused" to its owner — used by Night Shift to flip the live
    /// calibration preview on while a Darkness/Warmth chip is focused.
    @FocusState private var focusedOption: Option?

    /// - Parameters:
    ///   - options: The selectable values, left-to-right.
    ///   - selection: The current selection; tapping a chip writes it back.
    ///   - icon: Optional SF Symbol name shown before each chip's title. Return
    ///     `nil` (the default) for a text-only chip.
    ///   - onFocusChange: Called with `true` when any chip in the row gains focus
    ///     and `false` when focus leaves the row. Use for live-preview hooks.
    ///   - title: The chip's display text for an option.
    public init(
        options: [Option],
        selection: Binding<Option>,
        icon: @escaping (Option) -> String? = { _ in nil },
        onFocusChange: ((Bool) -> Void)? = nil,
        title: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.icon = icon
        self.onFocusChange = onFocusChange
        self.title = title
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        HStack(spacing: 10) {
                            if let symbol = icon(option) {
                                Image(systemName: symbol)
                            }
                            Text(title(option))
                            if selection == option {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        .font(.headline)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(PlozzSeasonTabStyle(isSelected: selection == option))
                    .focused($focusedOption, equals: option)
                    .accessibilityValue(selection == option ? "Selected" : "")
                }
            }
            // Padding so a focused chip's scale lift is never clipped by the
            // horizontal scroll view.
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .scrollClipDisabled()
        .onChange(of: focusedOption) { _, focused in
            onFocusChange?(focused != nil)
        }
    }
}

#endif
