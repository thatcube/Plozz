#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// A vertical, checkable list of options for the Settings detail pane: one
/// focusable row per option with a leading icon, its title, and a trailing
/// checkmark on the current selection.
///
/// This is the vertical counterpart to ``SettingsOptionPicker`` (the horizontal
/// "season tab" pill strip). It reuses the shared ``SettingsRowLabel`` +
/// ``SettingsFocusButtonStyle`` so every option reads as the same inverted
/// focus card as the rest of Settings, and it scans far better than a pill row
/// when a setting has a handful of mutually-exclusive choices (Theme, Display
/// Size, Music Player style) — you glance down the column and the checkmark
/// tells you the current pick.
struct SettingsOptionList<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var icon: (Option) -> String? = { _ in nil }
    /// Called with `true` when any row in the list gains focus and `false` when
    /// focus leaves the list entirely. Mirrors ``SettingsOptionPicker``'s hook —
    /// Circadian Mode uses it to flip the live tint preview on while a
    /// Darkness/Warmth row is focused.
    var onFocusChange: ((Bool) -> Void)? = nil
    let title: (Option) -> String

    /// Tracks which row (if any) currently holds focus so the list can report
    /// "I am focused" to its owner for live-preview hooks.
    @FocusState private var focusedOption: Option?

    // ``SettingsRowLabel`` insets its content by 12pt horizontally; cancel the
    // leading inset so the option titles line up flush-left with the pane
    // heading and description, while the focus card still bleeds outward
    // symmetrically (same trick as ``SettingsSwitchToggleStyle``).
    private let labelInset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    // Mirror SettingsSwitchToggleBody's metrics exactly (spacing
                    // 20, headline-semibold label, 14pt vertical padding, 46pt
                    // min height) so a checkable option row carries the same
                    // visual weight as a toggle row elsewhere on this screen.
                    HStack(spacing: 20) {
                        if let symbol = icon(option) {
                            Image(systemName: symbol)
                                .font(.system(size: 24, weight: .semibold))
                                .frame(width: 34, alignment: .center)
                                .settingsRowIcon()
                        }
                        Text(title(option))
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 20)
                        Image(systemName: "checkmark")
                            .font(.title3.weight(.bold))
                            .opacity(selection == option ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 46)
                    .padding(.vertical, 14)
                    .padding(.horizontal, labelInset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsFocusButtonStyle())
                .focused($focusedOption, equals: option)
                .padding(.leading, -labelInset)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .onChange(of: focusedOption) { _, focused in
            onFocusChange?(focused != nil)
        }
    }
}

#endif
