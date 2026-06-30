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
/// back to the master list.
///
/// Two indicators stack, and never get confused for one another:
/// * **Selection** — a brand-green thumb (matching the switch toggles) marks the
///   chosen segment. It is `matchedGeometryEffect`-shared across the segments, so
///   changing the choice makes it *glide* from the old segment to the new one
///   with a springy settle rather than blinking in place.
/// * **Focus** — the bright white tvOS thumb (with lift + shadow) marks where
///   focus currently sits. Focus always draws on top, so the highlighted segment
///   is obvious across the room even when it is also the selected one.
///
/// Best for 2–5 short options. For long labels or many options prefer a menu or
/// a vertical list instead.
struct SettingsSegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    @Environment(\.themePalette) private var palette
    /// Shared namespace so the green selection thumb can slide between segments.
    @Namespace private var indicatorNamespace

    /// The "chosen" green, matched to the on-state of the switch toggles so the
    /// whole Settings surface speaks one "this is active" colour. Deliberately
    /// NOT `palette.accent`: on tvOS the (empty) AccentColor asset resolves to
    /// white, which would render white-on-white here.
    private static var selectedFill: Color { Color(red: 0.20, green: 0.78, blue: 0.36) }

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
                .buttonStyle(SegmentStyle(
                    isSelected: selection == option,
                    namespace: indicatorNamespace,
                    selectedFill: Self.selectedFill
                ))
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
        // Springy settle drives the matchedGeometry slide of the green thumb.
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: selection)
    }

    /// One segment. The fill is composed in a ZStack so the sliding green
    /// selection thumb and the bright white focus thumb are independent layers.
    private struct SegmentStyle: ButtonStyle {
        let isSelected: Bool
        let namespace: Namespace.ID
        let selectedFill: Color

        func makeBody(configuration: Configuration) -> some View {
            SegmentBody(
                configuration: configuration,
                isSelected: isSelected,
                namespace: namespace,
                selectedFill: selectedFill
            )
        }

        private struct SegmentBody: View {
            let configuration: ButtonStyle.Configuration
            let isSelected: Bool
            let namespace: Namespace.ID
            let selectedFill: Color
            @Environment(\.isFocused) private var isFocused
            @Environment(\.themePalette) private var palette

            /// Text always contrasts whatever thumb is behind it: black on the
            /// white focus thumb, white on the green selection thumb, otherwise
            /// the dimmed idle tint.
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
                    .background {
                        ZStack {
                            // Selection thumb: present only on the chosen segment,
                            // shared across all segments so it glides between them.
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(selectedFill)
                                    .matchedGeometryEffect(id: "segment-selection", in: namespace)
                            }
                            // Focus thumb: the bright tvOS highlight, on top so it
                            // wins over the selection thumb when both apply.
                            if isFocused {
                                Capsule(style: .continuous)
                                    .fill(.white)
                            }
                        }
                    }
                    .shadow(
                        color: .black.opacity(isFocused ? 0.25 : 0),
                        radius: isFocused ? 8 : 0,
                        y: isFocused ? 3 : 0
                    )
                    .scaleEffect(isFocused ? 1.05 : 1.0)
                    .opacity(configuration.isPressed ? 0.9 : 1)
                    .animation(.easeOut(duration: 0.16), value: isFocused)
            }
        }
    }
}
#endif
