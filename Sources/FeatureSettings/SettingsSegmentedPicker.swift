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
/// ## Interaction (press to commit — focus and selection are decoupled)
/// This behaves like every other tvOS control, because on tvOS focus is purely
/// spatial: moving focus across the segments changes **nothing**; you press
/// **Select** to commit the focused segment. A left press at the leading edge
/// just leaves the control back to the master list (standard), and moving
/// up/down to a neighbouring control never grabs the wrong value because focus
/// doesn't drive selection.
///
/// ## Look (monochrome, theme-aware)
/// Two independent, non-competing indicators:
/// * **Focus** — the segment you're on wears the same theme-aware bright thumb
///   as every other Settings row (WHITE thumb + black text in dark themes, BLACK
///   thumb + white text in light themes), with a soft lift.
/// * **Selection** — the chosen segment carries a trailing checkmark (matching
///   ``SettingsOptionPicker``) and brighter label, with no colour. The checkmark
///   slot is always reserved, so committing a choice never resizes the track or
///   disturbs focus geometry.
///
/// Best for 2–5 short options. For long labels or many options prefer a menu or
/// a vertical list instead.
struct SettingsSegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    /// Reports the option under focus as the user moves across the segments —
    /// before any Select/commit — and `nil` when focus leaves the control. Lets a
    /// caller mirror the focused option's own description live, decoupled from
    /// `selection` (which only changes on Select).
    var onFocusedOptionChange: ((Option?) -> Void)? = nil

    @FocusState private var focusedOption: Option?
    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    SegmentLabel(
                        text: title(option),
                        isSelected: option == selection
                    )
                }
                .buttonStyle(SegmentButtonStyle(isSelected: option == selection))
                .focused($focusedOption, equals: option)
                .accessibilityValue(option == selection ? "Selected" : "")
            }
        }
        // Generous inset so a focused segment's bright thumb and lift have room
        // to breathe inside the track instead of crowding the rim.
        .padding(8)
        .background(
            Capsule(style: .continuous)
                .fill(palette.cardSurface.opacity(0.45))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(palette.cardBorder.opacity(0.8), lineWidth: 1)
        )
        .fixedSize()
        // Surface focus movement so a caller can live-update a description of the
        // focused option — decoupled from selection, which only changes on Select.
        .onChange(of: focusedOption) { _, newValue in
            onFocusedOptionChange?(newValue)
        }
    }

    /// The contents of one segment: the label, plus a trailing checkmark shown
    /// only on the selected segment. The label always reserves its *semibold*
    /// width (via a hidden sizing copy) so changing weight never reflows the
    /// text, and the checkmark is laid out inline only when present so unselected
    /// segments don't carry an empty gap.
    private struct SegmentLabel: View {
        let text: String
        let isSelected: Bool

        var body: some View {
            HStack(spacing: 8) {
                Text(text)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        // Reserve the bold metrics in every state so the label
                        // is sized as if always semibold — the visible weight can
                        // change without nudging the content.
                        Text(text)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .fixedSize()
                            .hidden()
                    )
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// Press-to-commit segment styling. Focus draws the theme-aware bright thumb
    /// (decoupled from selection); a merely-selected segment keeps a brighter
    /// label + checkmark on the plain track.
    private struct SegmentButtonStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            SegmentBody(configuration: configuration, isSelected: isSelected)
        }

        private struct SegmentBody: View {
            let configuration: ButtonStyle.Configuration
            let isSelected: Bool
            @Environment(\.isFocused) private var isFocused
            @Environment(\.colorScheme) private var colorScheme
            @Environment(\.themePalette) private var palette

            // Theme-aware focus thumb, mirroring `SettingsFocusButtonStyle`:
            // invert against the background so the highlight reads in every theme.
            private var focusThumbFill: Color { colorScheme == .dark ? .white : .black }
            private var focusThumbText: Color { colorScheme == .dark ? .black : .white }

            private var foreground: Color {
                if isFocused { return focusThumbText }
                if isSelected { return palette.primaryText }
                return palette.secondaryText
            }

            // Selection wears a subtle neutral fill (no colour) so the chosen
            // segment reads as a soft inset chip even from across the room; the
            // focus thumb still overrides it as the bright theme-aware highlight.
            private var segmentFill: Color {
                if isFocused { return focusThumbFill }
                if isSelected { return palette.primaryText.opacity(0.14) }
                return .clear
            }

            var body: some View {
                configuration.label
                    .font(.headline)
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background {
                        Capsule(style: .continuous)
                            .fill(segmentFill)
                            .shadow(
                                color: .black.opacity(isFocused ? 0.25 : 0),
                                radius: isFocused ? 8 : 0,
                                y: isFocused ? 3 : 0
                            )
                    }
                    .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.04 : 1.0))
                    .animation(.easeOut(duration: 0.16), value: isFocused)
                    .animation(.easeOut(duration: 0.16), value: isSelected)
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            }
        }
    }
}
#endif
