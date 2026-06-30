#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// A compact − / value / + stepper for dialing a value through an ordered set of
/// presets (e.g. skip intervals).
///
/// The − and + are *discrete focusable buttons*: you move focus between them with
/// left/right and press **Select** to step. Deliberately not a value-on-left/right
/// slider — that would hijack the left-press the split layout relies on to return
/// focus to the master list. Here, a left-press from the − button just leaves the
/// control like any other. The value clamps at the ends of the preset list.
struct SettingsStepper<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    @Environment(\.themePalette) private var palette

    private var index: Int { options.firstIndex(of: selection) ?? 0 }
    private var canDecrement: Bool { index > 0 }
    private var canIncrement: Bool { index < options.count - 1 }

    var body: some View {
        HStack(spacing: 24) {
            stepButton(symbol: "minus", dimmed: !canDecrement) {
                if canDecrement { selection = options[index - 1] }
            }

            // Reserve the widest option's width (hidden sizers behind the live
            // value) so stepping between variable-width labels — e.g. "None" vs
            // "Drop Shadow" — never nudges the − / + buttons.
            ZStack {
                ForEach(options.indices, id: \.self) { i in
                    valueLabel(title(options[i])).hidden()
                }
                valueLabel(title(selection))
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 96)
            .animation(.easeOut(duration: 0.16), value: index)

            stepButton(symbol: "plus", dimmed: !canIncrement) {
                if canIncrement { selection = options[index + 1] }
            }
        }
        .fixedSize()
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(palette.primaryText)
    }

    private func stepButton(symbol: String, dimmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 72, height: 72)
                // Dim the glyph at the ends, but keep the button focusable so the
                // left-exit point stays consistent (always the − button).
                .opacity(dimmed ? 0.35 : 1)
        }
        .buttonStyle(StepperButtonStyle())
    }
}

/// Round step button mirroring the segmented picker's theme-aware focus thumb:
/// a subtle neutral chip at rest, the bright inverted thumb (white-on-dark /
/// black-on-light) when focused.
private struct StepperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StepperButtonBody(configuration: configuration)
    }

    private struct StepperButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.themePalette) private var palette

        private var fill: Color {
            if isFocused { return colorScheme == .dark ? .white : .black }
            return palette.primaryText.opacity(0.14)
        }
        private var foreground: Color {
            if isFocused { return colorScheme == .dark ? .black : .white }
            return palette.primaryText
        }

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background(
                    Circle()
                        .fill(fill)
                        .shadow(
                            color: .black.opacity(isFocused ? 0.25 : 0),
                            radius: isFocused ? 8 : 0,
                            y: isFocused ? 3 : 0
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.08 : 1.0))
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
#endif
