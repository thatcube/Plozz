#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// How much visual weight a checkable row carries, so the *same* shared control
/// can read as either a top-level decision or a child of a master toggle — no
/// one-off row types.
///
/// - `primary`: full weight, matching a switch row on the same screen. For
///   single-select pickers where the checkmark list *is* the decision (Theme,
///   Display Size, Music Player style — see ``SettingsOptionList``).
/// - `secondary`: a step lighter + tighter, for sub-section multi-select lists
///   that sit under a master toggle (Customize Home rows, the libraries under a
///   server on Your Servers & Libraries — see ``SettingsCheckList``). Reads as
///   the toggle's children, not its peer.
enum SettingsRowProminence {
    case primary
    case secondary
}

/// One focusable, checkable row for the Settings detail pane — a leading optional
/// icon, a title, and a trailing checkmark shown when `isChecked`.
///
/// Shared by both ``SettingsOptionList`` (single-select — Theme, Display Size,
/// Music Player style) and ``SettingsCheckList`` (multi-select — the Customize
/// Home row checklists), so the checkmark and focus-card look are identical
/// everywhere and defined **once**. At `.primary` prominence it mirrors
/// ``SettingsSwitchToggleStyle``'s metrics (spacing 20, headline-semibold label,
/// 14pt vertical padding, 46pt min height) so a checkable row carries the same
/// weight as a switch row; `.secondary` steps that down for child rows.
struct SettingsCheckableRow: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    let isChecked: Bool
    /// When false the row is dimmed and pulled out of the focus order (can't be
    /// selected). `SettingsFocusButtonStyle` ignores `\.isEnabled`, so `.disabled`
    /// alone wouldn't dim it — the opacity below supplies the disabled look.
    var isEnabled: Bool = true
    /// Full weight (default) or a lighter child treatment — see
    /// ``SettingsRowProminence``.
    var prominence: SettingsRowProminence = .primary
    let action: () -> Void

    // ``SettingsRowLabel`` insets content by 12pt horizontally; cancel the leading
    // inset so titles line up flush-left with the pane heading while the focus
    // card still bleeds outward symmetrically. Same at both prominences so a
    // secondary child list stays aligned under its master toggle.
    private let labelInset: CGFloat = 12

    private var rowSpacing: CGFloat { prominence == .primary ? 20 : 16 }
    private var iconSize: CGFloat { prominence == .primary ? 24 : 20 }
    private var iconFrame: CGFloat { prominence == .primary ? 34 : 30 }
    private var titleFont: Font {
        prominence == .primary ? .headline.weight(.semibold) : .callout.weight(.medium)
    }
    private var minRowHeight: CGFloat { prominence == .primary ? 46 : 40 }
    private var verticalPadding: CGFloat { prominence == .primary ? 14 : 11 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: rowSpacing) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: iconSize, weight: .semibold))
                        .frame(width: iconFrame, alignment: .center)
                        .settingsRowIcon()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(titleFont)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: rowSpacing)
                SettingsCheckmark(isChecked: isChecked, prominence: prominence)
            }
            .frame(minHeight: minRowHeight)
            .padding(.vertical, verticalPadding)
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
/// `.title3` mark (maintainer feedback) so a column of them reads lighter, and
/// smaller again at `.secondary` prominence for child rows.
struct SettingsCheckmark: View {
    let isChecked: Bool
    var prominence: SettingsRowProminence = .primary

    private var glyphFont: Font {
        prominence == .primary ? .headline.weight(.bold) : .callout.weight(.bold)
    }

    var body: some View {
        Image(systemName: "checkmark")
            .font(glyphFont)
            .opacity(isChecked ? 1 : 0)
            .accessibilityHidden(true)
    }
}
#endif
