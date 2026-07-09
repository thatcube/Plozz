#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings picker for the card style: a two-up row of preview
/// cards (`PreviewCard` + `CardStyleSwatch`) that share the detail pane's width,
/// mirroring `CompactWatchIndicatorPicker`. Tapping a card selects that style; the
/// active one carries the same accent wash/ring the theme and watch-indicator
/// pickers use.
///
/// With only two choices there's plenty of horizontal room, so each card's
/// preview is given the same taller swatch the watch-indicator picker uses, so the
/// framed-vs-borderless illustration reads clearly.
struct CompactCardStylePicker: View {
    @Binding var selection: CardStyle
    @Environment(\.themePalette) private var palette

    /// Matches `CompactWatchIndicatorPicker` — the two-up layout leaves room for a
    /// larger, more legible card illustration.
    private let swatchHeight: CGFloat = 248

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(CardStyle.allCases) { style in
                PreviewCard(
                    title: style.displayName,
                    detail: style.detail,
                    isSelected: selection == style,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    action: { selection = style }
                ) {
                    CardStyleSwatch(
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
