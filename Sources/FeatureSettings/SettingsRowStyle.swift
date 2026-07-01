#if canImport(SwiftUI)
import SwiftUI
import CoreUI

// The shared, theme-aware list-row focus style (`SettingsFocusButtonStyle`), its
// `SettingsRowSize`, the `settingsRowIsFocused` / `settingsRowFocusForeground`
// environment values, and the `.settingsRowSecondary()/Icon()/GreenIndicator()`
// helpers now live in CoreUI (`SettingsRowFocusStyle.swift`) so other modules —
// e.g. the music rails' "See All" — can focus identically instead of drifting
// from a private copy. The row body + switch toggle below still consume them via
// the `import CoreUI` above.

// MARK: - Shared row body (one- or two-line)

/// The shared body of a Settings list row: a leading icon, a primary `title`,
/// an optional SECOND line beneath the title, and a trailing accessory.
///
/// Wrap it in a `NavigationLink` or `Button` and apply
/// ``SettingsFocusButtonStyle`` to turn it into a live nav / toggle row — the
/// two-column shape stays identical whether the second line is descriptive
/// text, a strip of account avatars, or nothing at all, so every row reads as
/// one control family. Leave `secondary` unset for a plain one-line row; pass a
/// view (a subtitle, an avatar strip…) for the two-line variant. The `trailing`
/// slot carries a value + chevron for navigation, or an On/Off word for an
/// in-place toggle.
///
/// Row content adapts to focus automatically: pair inner text with
/// `.settingsRowSecondary()` so it inverts against the focus card.
struct SettingsRowLabel<Secondary: View, Trailing: View>: View {
    private let icon: String?
    private let title: String
    private let secondary: Secondary
    private let trailing: Trailing

    init(
        icon: String?,
        title: String,
        @ViewBuilder secondary: () -> Secondary = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.secondary = secondary()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 16) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .frame(width: 30, height: 30)
                    .settingsRowIcon()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.medium))
                secondary
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Switch-style Toggle for the detail pane

/// A tvOS switch-style `ToggleStyle` for the Settings detail pane.
///
/// tvOS has no native sliding switch — a default `Toggle` renders as a text
/// "On/Off" pill, which made detail toggles look almost identical to the left
/// navigation rows. This draws a real track-and-knob switch plus a compact
/// On/Off word, so a *control* is unmistakably a control and reads differently
/// from the chevroned *navigation* rows across the room (10-foot UI).
///
/// The whole row is a single focus target (reached by pressing right from the
/// master list); pressing Select flips the value. It is applied once on the
/// detail pane via `.toggleStyle(...)`, so every converted page's toggles adopt
/// it together. The switch graphic + On/Off label are coloured explicitly so
/// they stay legible on the inverted focus card.
struct SettingsSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitchToggleBody(configuration: configuration)
    }
}

private struct SettingsSwitchToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    // Horizontal breathing room inside the focus pill. The same amount is pulled
    // back off the leading edge below, so the *label* lines up flush-left with
    // the pane heading, description and the rows above/below it — while the pill
    // (drawn by the button style, which bleeds outward on focus) still keeps a
    // symmetric cushion around the content.
    private let hInset: CGFloat = 12

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 20) {
                configuration.label
                    .font(.headline.weight(.semibold))
                    // Keep every detail-pane toggle label on a single line. The
                    // labels are kept short enough to fit at full size (the pane
                    // heading + description above carry the detail), so this only
                    // guards against an accidental wrap — never shrinks the text.
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
        // Cancel the leading inset so the label sits flush with the flush-left
        // content around it; the focus pill simply extends that much further to
        // the left, staying centered on the content.
        .padding(.leading, -hInset)
    }
}

/// The track-and-knob graphic plus the On/Off state word. Reads the shared
/// settings focus environment so it stays legible against the inverted
/// (white-in-dark-mode) focus card.
///
/// The switch is monochrome — the same theme-aware ink/paper vocabulary as the
/// segmented picker and stepper thumbs — rather than the stock green. The state
/// word is neutral; the *switch* alone communicates on/off, with the filled ink
/// track reading clearly as "on".
private struct SettingsSwitchIndicator: View {
    let isOn: Bool
    @Environment(\.settingsRowIsFocused) private var isFocused
    @Environment(\.settingsRowFocusForeground) private var focusFg
    @Environment(\.colorScheme) private var colorScheme

    private let trackWidth: CGFloat = 84
    private let trackHeight: CGFloat = 46
    private var knobSize: CGFloat { trackHeight - 10 }
    private var travel: CGFloat { (trackWidth - knobSize) / 2 - 4 }

    /// Whether the surface *behind* the switch reads as dark. On a focus card
    /// the surface flips — a dark-mode focus card is white — so ink and paper
    /// invert to stay legible.
    private var surfaceIsDark: Bool {
        isFocused ? (colorScheme == .light) : (colorScheme == .dark)
    }

    /// High-contrast "ink" (the filled on-track) and its "paper" opposite (the
    /// knob), so the knob reads as a cutout on the filled track.
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
