#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The Display Size picker, drawn as a **visual size ramp**: one focusable row
/// per `UIDensity`, each showing a strip of mock poster cards at that density's
/// true relative scale (via ``DisplaySizeSwatch``). Stacked top-to-bottom the
/// rows read small → large, so the choice looks like what it does — the same
/// "show me the feature" treatment Card Style and Watched Indicator already use,
/// instead of a plain checkmark list with abstract grid glyphs.
///
/// Structurally a sibling of ``SettingsCheckableRow`` (shared checkmark, focus
/// card, metrics) with the preview strip inserted between the name column and
/// the trailing checkmark. Single-select, bound to the profile's density.
struct CompactDisplaySizePicker: View {
    @Binding var selection: UIDensity

    @FocusState private var focused: UIDensity?

    /// Fixed leading column so every preview strip shares the same left origin —
    /// that shared origin is what lets the eye read the widths as a ramp.
    private let labelWidth: CGFloat = 132
    private var labelInset: CGFloat { SettingsRowMetrics.horizontalPadding }

    var body: some View {
        SettingsCheckGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(UIDensity.allCases) { density in
                    row(density)
                        .focused($focused, equals: density)
                }
            }
        }
    }

    private func row(_ density: UIDensity) -> some View {
        Button {
            selection = density
        } label: {
            HStack(spacing: SettingsRowMetrics.spacing(.primary)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(density.displayName)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(density.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: labelWidth, alignment: .leading)

                DisplaySizeSwatch(density: density)
                    .frame(maxWidth: .infinity, alignment: .leading)

                SettingsCheckmark(isChecked: selection == density)
            }
            .frame(minHeight: SettingsRowMetrics.minHeight(.primary))
            .padding(.vertical, SettingsRowMetrics.verticalPadding(.primary))
            .padding(.horizontal, labelInset)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle())
        .padding(.leading, -labelInset)
        .accessibilityLabel(Text(density.displayName))
        .accessibilityValue(Text(density.detail))
        .accessibilityAddTraits(selection == density ? .isSelected : [])
    }
}
#endif
