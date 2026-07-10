#if canImport(SwiftUI)
import SwiftUI

// MARK: - Switch-style Toggle (shared)

/// A tvOS switch-style `ToggleStyle` used across the app — the Settings detail
/// pane AND the onboarding library picker — so every real on/off control looks
/// identical instead of drifting from a private copy.
///
/// tvOS has no native sliding switch — a default `Toggle` renders as a text
/// "On/Off" pill, which reads almost identically to a navigation row. This draws
/// a real track-and-knob switch plus a compact On/Off word, so a *control* is
/// unmistakably a control and reads differently from the chevroned *navigation*
/// rows across the room (10-foot UI).
///
/// The whole row is a single focus target; pressing Select flips the value. The
/// switch graphic + On/Off label are coloured explicitly so they stay legible on
/// the inverted focus card (via the shared `settingsRow*` focus environment).
public struct SettingsSwitchToggleStyle: ToggleStyle {
    /// When false the row does NOT pull its leading edge outward — pass this
    /// inside a bordered card so the focus card nests concentrically instead of
    /// hugging the card's border. Default true (flush-left, for the borderless
    /// split-detail panes where the title lines up with the pane heading).
    var flushLeading: Bool

    public init(flushLeading: Bool = true) {
        self.flushLeading = flushLeading
    }

    public func makeBody(configuration: Configuration) -> some View {
        SettingsSwitchToggleBody(configuration: configuration, flushLeading: flushLeading)
    }
}

private struct SettingsSwitchToggleBody: View {
    let configuration: ToggleStyleConfiguration
    let flushLeading: Bool
    @Environment(\.isEnabled) private var isEnabled

    // Horizontal breathing room inside the focus pill (shared token). The same
    // amount is pulled back off the leading edge below (unless `flushLeading` is
    // off), so the *label* lines up flush-left with the content around it — while
    // the pill (drawn by the button style, which bleeds outward on focus) still
    // keeps a symmetric cushion around it.
    private var hInset: CGFloat { SettingsRowMetrics.horizontalPadding }

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: SettingsRowMetrics.spacing(.primary)) {
                configuration.label
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: SettingsRowMetrics.spacing(.primary))
                SettingsSwitchIndicator(isOn: configuration.isOn)
            }
            .frame(minHeight: SettingsRowMetrics.minHeight(.primary))
            .padding(.vertical, SettingsRowMetrics.verticalPadding(.primary))
            .padding(.horizontal, hInset)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
        .padding(.leading, flushLeading ? -hInset : 0)
    }
}

/// A switch-style control identical in look to `SettingsSwitchToggleStyle`, but
/// with an explicit `canFocus` gate.
///
/// Unlike a stock `Toggle` (whose internal `Button` can't be removed from focus
/// with `.focusable(false)`, and where `.disabled` dims the row), this owns its
/// `Button` and renders with the custom `SettingsFocusButtonStyle`, which ignores
/// `\.isEnabled`. So `.disabled(!canFocus)` takes the control out of the focus
/// order **without** dimming it — letting a caller steer where a directional
/// focus move lands (e.g. keep this off the focus map until sibling controls have
/// been focused) while it still looks fully enabled.
public struct FocusGatedSwitch: View {
    private let title: String
    @Binding private var isOn: Bool
    private let canFocus: Bool
    private var hInset: CGFloat { SettingsRowMetrics.horizontalPadding }

    public init(_ title: String, isOn: Binding<Bool>, canFocus: Bool = true) {
        self.title = title
        self._isOn = isOn
        self.canFocus = canFocus
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: SettingsRowMetrics.spacing(.primary)) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: SettingsRowMetrics.spacing(.primary))
                SettingsSwitchIndicator(isOn: isOn)
            }
            .frame(minHeight: SettingsRowMetrics.minHeight(.primary))
            .padding(.vertical, SettingsRowMetrics.verticalPadding(.primary))
            .padding(.horizontal, hInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
        .padding(.leading, -hInset)
        // Custom button style ignores `\.isEnabled`, so disabling only removes it
        // from the focus order — no dimming.
        .disabled(!canFocus)
    }
}

/// A plain `Button` that looks EXACTLY like `SettingsSwitchToggleStyle` (same
/// track-and-knob switch + On/Off word), but is a button, not a `Toggle`, and
/// takes an arbitrary `label`.
///
/// Use this when "on/off" is really a **side-effectful action** rather than a
/// simple boolean binding — e.g. the per-profile server master switch, where one
/// press expands/collapses a whole card and mutates a multi-account set. A plain
/// `Button` makes the press path unambiguous on tvOS (a real `Toggle` with a
/// custom style drove nothing here), and reading `isOn` from live state each
/// render keeps it honest even when the hosting screen is a cached navigation
/// destination.
public struct SettingsSwitchButton<Label: View>: View {
    private let isOn: Bool
    private let flushLeading: Bool
    private let action: () -> Void
    @ViewBuilder private let label: () -> Label
    private var hInset: CGFloat { SettingsRowMetrics.horizontalPadding }

    public init(
        isOn: Bool,
        flushLeading: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isOn = isOn
        self.flushLeading = flushLeading
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsRowMetrics.spacing(.primary)) {
                label()
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: SettingsRowMetrics.spacing(.primary))
                SettingsSwitchIndicator(isOn: isOn)
            }
            .frame(minHeight: SettingsRowMetrics.minHeight(.primary))
            .padding(.vertical, SettingsRowMetrics.verticalPadding(.primary))
            .padding(.horizontal, hInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
        .padding(.leading, flushLeading ? -hInset : 0)
    }
}

/// The track-and-knob graphic plus the On/Off state word. Reads the shared
/// settings focus environment so it stays legible against the inverted
/// (white-in-dark-mode) focus card.
private struct SettingsSwitchIndicator: View {
    let isOn: Bool
    @Environment(\.settingsRowIsFocused) private var isFocused
    @Environment(\.settingsRowFocusForeground) private var focusFg
    @Environment(\.colorScheme) private var colorScheme

    private let trackWidth: CGFloat = 84
    // Matches the primary row min-height so a switch row and a primary checkable
    // row are exactly the same height.
    private var trackHeight: CGFloat { SettingsRowMetrics.minHeight(.primary) }
    private var knobSize: CGFloat { trackHeight - 10 }
    private var travel: CGFloat { (trackWidth - knobSize) / 2 - 4 }

    private var surfaceIsDark: Bool {
        isFocused ? (colorScheme == .light) : (colorScheme == .dark)
    }

    private var ink: Color { surfaceIsDark ? .white : .black }
    private var paper: Color { surfaceIsDark ? .black : .white }

    private var trackColor: Color {
        isOn ? ink : ink.opacity(isFocused ? 0.22 : 0.18)
    }
    private var knobColor: Color { isOn ? paper : ink }

    private var stateWordColor: AnyShapeStyle {
        if isFocused { return AnyShapeStyle(focusFg.opacity(0.7)) }
        return AnyShapeStyle(.secondary)
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(isOn ? "On" : "Off")
                .font(.callout.weight(.semibold))
                .foregroundStyle(stateWordColor)
                .frame(width: 48, alignment: .trailing)

            ZStack {
                Capsule(style: .continuous)
                    .fill(trackColor)
                Circle()
                    .fill(knobColor)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .offset(x: isOn ? travel : -travel)
            }
            .frame(width: trackWidth, height: trackHeight)
            .animation(.easeOut(duration: 0.18), value: isOn)
        }
    }
}
#endif
