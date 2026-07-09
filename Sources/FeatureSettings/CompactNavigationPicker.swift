#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings picker for the navigation style: a two-up row of
/// preview cards (`PreviewCard` + `NavigationStyleSwatch`) that share the detail
/// pane's width, mirroring `CompactWatchIndicatorPicker`. Tapping a card selects
/// that chrome; the active one carries the same accent wash/ring the theme and
/// card-style pickers use.
///
/// With only two choices there's plenty of horizontal room, so each card's
/// preview is given the same taller swatch the watch-indicator picker uses, so the
/// top-bar-vs-sidebar illustration reads clearly.
struct CompactNavigationPicker: View {
    @Binding var selection: NavigationStyle
    @Environment(\.themePalette) private var palette

    /// Matches `CompactWatchIndicatorPicker` — the two-up layout leaves room for a
    /// larger, more legible chrome illustration.
    private let swatchHeight: CGFloat = 248

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
