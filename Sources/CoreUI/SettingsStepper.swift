#if canImport(SwiftUI)
import SwiftUI

/// A compact − / value / + stepper for dialing a value through an ordered set of
/// presets (e.g. skip intervals, playback speed).
///
/// The − and + are *discrete focusable buttons*: you move focus between them with
/// left/right and press **Select** to step. Deliberately not a value-on-left/right
/// slider — that would hijack the left-press the split layout relies on to return
/// focus to the master list. Here, a left-press from the − button just leaves the
/// control like any other. The value clamps at the ends of the preset list.
public struct SettingsStepper<Value: Hashable>: View {
    public let options: [Value]
    @Binding public var selection: Value
    public let title: (Value) -> String
    /// Compact styling for tight surfaces (e.g. the in-player Speed menu): smaller
    /// − / + buttons and a body-size value that matches the preset rows beside it,
    /// so the stepper doesn't tower over the list. Defaults to the roomy style used
    /// on the full Settings pages.
    public let compact: Bool
    /// When true the value wraps from the last option back to the first (and vice
    /// versa) and the − / + buttons never dim — for cyclic ranges like a clock
    /// time. When false (the default) the value clamps at the ends of the preset
    /// list and the end arrow dims.
    public let wraps: Bool
    /// Called with `true` when either the − or + button gains focus and `false`
    /// when focus leaves the stepper. Lets a caller drive a live preview while the
    /// user is dialing the value (e.g. Circadian's Darkness/Warmth tint preview),
    /// mirroring ``SettingsOptionPicker``'s hook.
    public let onFocusChange: ((Bool) -> Void)?

    @Environment(\.themePalette) private var palette
    @FocusState private var focusedButton: StepperButton?

    private enum StepperButton { case minus, plus }

    public init(
        options: [Value],
        selection: Binding<Value>,
        compact: Bool = false,
        wraps: Bool = false,
        onFocusChange: ((Bool) -> Void)? = nil,
        title: @escaping (Value) -> String
    ) {
        self.options = options
        self._selection = selection
        self.compact = compact
        self.wraps = wraps
        self.onFocusChange = onFocusChange
        self.title = title
    }

    private var index: Int { options.firstIndex(of: selection) ?? 0 }
    private var canDecrement: Bool { wraps || index > 0 }
    private var canIncrement: Bool { wraps || index < options.count - 1 }

    private func stepped(by delta: Int) -> Value? {
        guard !options.isEmpty else { return nil }
        let count = options.count
        if wraps {
            return options[((index + delta) % count + count) % count]
        }
        let target = index + delta
        guard options.indices.contains(target) else { return nil }
        return options[target]
    }

    private var buttonSize: CGFloat { compact ? 46 : 72 }
    private var glyphSize: CGFloat { compact ? 16 : 26 }
    private var rowSpacing: CGFloat { compact ? 12 : 24 }
    private var valueMinWidth: CGFloat { compact ? 52 : 96 }
    private var valueFont: Font { compact ? .body : .headline.weight(.semibold) }

    public var body: some View {
        HStack(spacing: rowSpacing) {
            stepButton(symbol: "minus", dimmed: !canDecrement, focus: .minus) {
                if let next = stepped(by: -1) { selection = next }
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
            .frame(minWidth: valueMinWidth)
            .animation(.easeOut(duration: 0.16), value: index)

            stepButton(symbol: "plus", dimmed: !canIncrement, focus: .plus) {
                if let next = stepped(by: 1) { selection = next }
            }
        }
        .fixedSize()
        // Report focus entering/leaving the stepper as a whole (either button) so
        // a caller can drive a live preview while the value is being dialed.
        .onChange(of: focusedButton) { _, focused in
            onFocusChange?(focused != nil)
        }
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .font(valueFont)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(palette.primaryText)
    }

    private func stepButton(symbol: String, dimmed: Bool, focus: StepperButton, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .frame(width: buttonSize, height: buttonSize)
                // Dim the glyph at the ends, but keep the button focusable so the
                // left-exit point stays consistent (always the − button).
                .opacity(dimmed ? 0.35 : 1)
        }
        .buttonStyle(StepperButtonStyle())
        .focused($focusedButton, equals: focus)
    }
}

/// Round step button mirroring the segmented picker's theme-aware focus thumb:
/// a subtle neutral chip at rest, the bright inverted thumb (white-on-dark /
/// black-on-light) when focused. Public so compact ± steppers built outside this
/// component (e.g. the in-player subtitle-sync control) share the exact look.
public struct StepperButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
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
