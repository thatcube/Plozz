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
/// ## Interaction (selection follows focus)
/// The whole control reads as one element. Spatial-right from the master list
/// enters it **on the current choice** (so entering never changes the value);
/// left/right then slide a **single thumb** between options and commit the new
/// value live; a left press at the leading edge leaves the control back to the
/// list. Because the thumb moves *with* your input, the slide is always visible.
///
/// ## Look (monochrome, theme-aware)
/// There is exactly one indicator — no accent colour (colour is reserved for the
/// rare true call-to-action, and the on/off switches). The thumb wears the same
/// theme-aware focus treatment as every other Settings row: a WHITE thumb with
/// black text in dark themes, a BLACK thumb with white text in light themes.
/// When focus leaves the control the thumb dims to a quiet neutral fill so the
/// current choice is still legible from the master list.
///
/// Best for 2–5 short options. For long labels or many options prefer a menu or
/// a vertical list instead.
struct SettingsSegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    /// Shared namespace so the single thumb glides between segments.
    @Namespace private var thumbNamespace
    /// Which segment currently holds focus (nil when focus is elsewhere).
    @FocusState private var focusedOption: Option?

    private var controlIsFocused: Bool { focusedOption != nil }

    /// The segment the thumb sits under: the focused one while we're inside the
    /// control, otherwise the committed selection.
    private var thumbOption: Option { focusedOption ?? selection }

    // Theme-aware focus thumb, mirroring `SettingsFocusButtonStyle`: invert
    // against the background so the highlight reads in every theme.
    private var focusThumbFill: Color { colorScheme == .dark ? .white : .black }
    private var focusThumbText: Color { colorScheme == .dark ? .black : .white }
    /// Quiet thumb shown when the control isn't focused — enough to mark the
    /// current choice from across the room without shouting.
    private var idleThumbFill: Color { palette.primaryText.opacity(0.16) }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        // Generous inset so the thumb (and its lift shadow) has room to breathe
        // inside the track instead of crowding the rim or its neighbours.
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
        // Entering the control lands on the current choice, so just arriving
        // never mutates the value.
        .defaultFocus($focusedOption, selection)
        // Selection follows focus: moving between segments commits live.
        .onChange(of: focusedOption) { _, newValue in
            if let newValue { selection = newValue }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: thumbOption)
        .animation(.easeOut(duration: 0.16), value: controlIsFocused)
    }

    @ViewBuilder
    private func segment(_ option: Option) -> some View {
        let isThumb = option == thumbOption

        Button {
            selection = option
        } label: {
            Text(title(option))
                .lineLimit(1)
                .fixedSize()
                .font(.headline.weight(isThumb ? .semibold : .regular))
                .foregroundStyle(segmentForeground(isThumb: isThumb))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background {
                    if isThumb {
                        Capsule(style: .continuous)
                            .fill(controlIsFocused ? focusThumbFill : idleThumbFill)
                            .matchedGeometryEffect(id: "segment-thumb", in: thumbNamespace)
                            .shadow(
                                color: .black.opacity(controlIsFocused ? 0.25 : 0),
                                radius: controlIsFocused ? 8 : 0,
                                y: controlIsFocused ? 3 : 0
                            )
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(SegmentButtonStyle())
        .focused($focusedOption, equals: option)
        .accessibilityValue(option == selection ? "Selected" : "")
    }

    private func segmentForeground(isThumb: Bool) -> Color {
        guard isThumb else { return palette.secondaryText }
        return controlIsFocused ? focusThumbText : palette.primaryText
    }

    /// Minimal style: keeps the segment focusable on tvOS without layering the
    /// system "card" lift on top of our own thumb.
    private struct SegmentButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.9 : 1)
        }
    }
}
#endif
