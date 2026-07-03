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
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SettingsSwitchToggleBody(configuration: configuration)
    }
}

private struct SettingsSwitchToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    // Horizontal breathing room inside the focus pill. The same amount is pulled
    // back off the leading edge below, so the *label* lines up flush-left with
    // the content around it — while the pill (drawn by the button style, which
    // bleeds outward on focus) still keeps a symmetric cushion around it.
    private let hInset: CGFloat = 12

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 20) {
                configuration.label
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 20)
                SettingsSwitchIndicator(isOn: configuration.isOn)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, hInset)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
        .padding(.leading, -hInset)
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
    private let trackHeight: CGFloat = 46
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
