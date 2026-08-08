#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings picker for the navigation style: a row of preview
/// cards (`PreviewCard` + `NavigationStyleSwatch`) that share the detail pane's
/// width, mirroring `CompactWatchIndicatorPicker`. Tapping a card selects that
/// chrome; the active one carries the same accent wash/ring the theme and
/// card-style pickers use.
struct CompactNavigationPicker: View {
    @Binding var selection: NavigationStyle
    @Environment(\.themePalette) private var palette

    /// Matches `CompactWatchIndicatorPicker`'s proportions, trimmed so three cards
    /// (rather than two) still read clearly across the detail pane's width.
    private let swatchHeight: CGFloat = 210

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(NavigationStyle.allCases) { style in
                PreviewCard(
                    title: style.displayName,
                    detail: style.detail,
                    isSelected: selection == style,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    action: { selection = style }
                ) {
                    NavigationStyleSwatch(
                        style: style,
                        cornerRadius: PlozzTheme.Metrics.Radius.content
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
