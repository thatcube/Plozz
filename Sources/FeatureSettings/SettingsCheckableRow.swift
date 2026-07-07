#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// One focusable, checkable row for the Settings detail pane — a leading optional
/// icon, a title, and a trailing checkmark shown when `isChecked`.
///
/// Shared by both ``SettingsOptionList`` (single-select — Theme, Display Size,
/// Music Player style) and ``SettingsCheckList`` (multi-select — the Customize
/// Home row checklists), so the checkmark and focus-card look are identical
/// everywhere and defined **once**. Mirrors ``SettingsSwitchToggleStyle``'s
/// metrics (spacing 20, headline-semibold label, 14pt vertical padding, 46pt min
/// height) so a checkable row carries the same weight as a switch row on the same
/// screen.
struct SettingsCheckableRow: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    let isChecked: Bool
    /// When false the row is dimmed and pulled out of the focus order (can't be
    /// selected). `SettingsFocusButtonStyle` ignores `\.isEnabled`, so `.disabled`
    /// alone wouldn't dim it — the opacity below supplies the disabled look.
    var isEnabled: Bool = true
    let action: () -> Void

    // ``SettingsRowLabel`` insets content by 12pt horizontally; cancel the leading
    // inset so titles line up flush-left with the pane heading while the focus
    // card still bleeds outward symmetrically.
    private let labelInset: CGFloat = 12

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 34, alignment: .center)
                        .settingsRowIcon()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 20)
                SettingsCheckmark(isChecked: isChecked)
            }
            .frame(minHeight: 46)
            .padding(.vertical, 14)
            .padding(.horizontal, labelInset)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(SettingsFocusButtonStyle())
        .disabled(!isEnabled)
        .padding(.leading, -labelInset)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}

/// The shared trailing checkmark glyph. Slightly smaller than the old inline
/// `.title3` mark (maintainer feedback) so a column of them reads lighter.
struct SettingsCheckmark: View {
    let isChecked: Bool

    var body: some View {
        Image(systemName: "checkmark")
            .font(.headline.weight(.bold))
            .opacity(isChecked ? 1 : 0)
            .accessibilityHidden(true)
    }
}
#endif
