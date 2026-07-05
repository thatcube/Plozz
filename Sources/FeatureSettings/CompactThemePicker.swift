#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings variant of the onboarding theme picker: a row of
/// smaller preview cards (`ThemeOptionCard(compact:)`) that share the detail
/// pane's width. Tapping a card selects that theme; the active one carries the
/// same accent wash/ring the full picker uses.
///
/// The swatches are theme-independent graphics, so this needs no device colour
/// scheme — it simply binds the selection.
struct CompactThemePicker: View {
    @Binding var selection: AppTheme
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(AppTheme.allCases) { theme in
                ThemeOptionCard(
                    theme: theme,
                    isSelected: selection == theme,
                    accent: palette.accent,
                    compact: true,
                    action: { selection = theme }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
