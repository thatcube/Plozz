#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// One focusable, checkable row for the Settings detail pane — a leading optional
/// icon, a title, and a trailing checkmark shown when `isChecked`.
///
/// Shared by both ``SettingsOptionList`` (single-select — Theme, Display Size,
/// Music Player style) and ``SettingsCheckList`` (multi-select — the Customize
/// Home row checklists), so the checkmark and focus-card look are identical
/// everywhere and defined **once**. All heights come from the shared
/// ``SettingsRowMetrics``, so at `.primary` prominence a checkable row is exactly
/// as tall as a switch row on the same screen, and `.secondary` steps that down
/// for child rows — matching selector rows of the same prominence.
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
    /// When false the row does NOT pull its leading edge outward — pass this
    /// inside a bordered card so the focus card nests concentrically instead of
    /// hugging the card's border. Default true (flush-left, for split panes).
    var flushLeading: Bool = true
    let action: () -> Void

    // ``SettingsRowLabel`` insets content horizontally; cancel the leading inset
    // (unless `flushLeading` is off) so titles line up flush-left with the pane
    // heading while the focus card still bleeds outward symmetrically.
    private var labelInset: CGFloat { SettingsRowMetrics.horizontalPadding }

    private var rowSpacing: CGFloat { SettingsRowMetrics.spacing(prominence) }
    private var iconSize: CGFloat { prominence == .primary ? 24 : 20 }
    private var iconFrame: CGFloat { prominence == .primary ? 34 : 30 }
    private var titleFont: Font {
        prominence == .primary ? .headline.weight(.semibold) : .callout.weight(.medium)
    }
    private var minRowHeight: CGFloat { SettingsRowMetrics.minHeight(prominence) }
    private var verticalPadding: CGFloat { SettingsRowMetrics.verticalPadding(prominence) }

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
        .padding(.leading, flushLeading ? -labelInset : 0)
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
