#if canImport(SwiftUI)
import SwiftUI

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
    let title: (Option) -> String

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
                    SettingsRowLabel(
                        icon: icon(option),
                        title: title(option),
                        trailing: {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.bold))
                                .opacity(selection == option ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                    )
                }
                .buttonStyle(SettingsFocusButtonStyle())
                .padding(.leading, -labelInset)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
    }
}

#endif
