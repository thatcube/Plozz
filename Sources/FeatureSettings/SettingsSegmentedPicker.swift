#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// A connected, segmented "pick one of a few" control for the Settings detail
/// pane.
///
/// Unlike ``SettingsOptionPicker`` (separate pills), this draws a single rounded
/// track split into segments — the iOS segmented idiom — so a short, fixed
/// choice (e.g. a subtitle mode: Off / On / Forced Only) reads unmistakably as
/// one multiple-choice control, distinct from the chevroned navigation rows and
/// the switch toggles.
///
/// Each segment is its own focus target: left/right moves between segments and
/// Select picks one; at the leading edge, another left press exits the control
/// back to the master list. The selected segment wears the accent thumb; the
/// focused segment lifts into the standard bright tvOS highlight.
///
/// Best for 2–5 short options. For long labels or many options prefer a menu or
/// a vertical list instead.
struct SettingsSegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(SegmentStyle(isSelected: selection == option))
                .accessibilityValue(selection == option ? "Selected" : "")
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(palette.cardSurface.opacity(0.45))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(palette.cardBorder.opacity(0.8), lineWidth: 1)
        )
        .fixedSize()
        .animation(.easeOut(duration: 0.16), value: selection)
    }

    /// One segment: a clear capsule normally, the accent thumb when selected, and
    /// the bright white focus thumb (with lift + shadow) when focused — focus
    /// always wins so the highlighted segment is obvious across the room.
    private struct SegmentStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            SegmentBody(configuration: configuration, isSelected: isSelected)
        }

        private struct SegmentBody: View {
            let configuration: ButtonStyle.Configuration
            let isSelected: Bool
            @Environment(\.isFocused) private var isFocused
            @Environment(\.themePalette) private var palette

            private var fill: Color {
                if isFocused { return .white }
                if isSelected { return palette.accent }
                return .clear
            }
            private var foreground: Color {
                if isFocused { return .black }
                if isSelected { return .white }
                return palette.secondaryText
            }

            var body: some View {
                configuration.label
                    .font(.headline.weight(isSelected || isFocused ? .semibold : .regular))
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule(style: .continuous).fill(fill))
                    .shadow(
                        color: .black.opacity(isFocused ? 0.25 : 0),
                        radius: isFocused ? 8 : 0,
                        y: isFocused ? 3 : 0
                    )
                    .scaleEffect(isFocused ? 1.05 : 1.0)
                    .opacity(configuration.isPressed ? 0.9 : 1)
                    .animation(.easeOut(duration: 0.16), value: isFocused)
                    .animation(.easeOut(duration: 0.16), value: isSelected)
            }
        }
    }
}
#endif
